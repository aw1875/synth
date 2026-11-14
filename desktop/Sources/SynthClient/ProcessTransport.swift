import Darwin
import Foundation
import SynthProtocol

final class ProcessTransport: Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostics: FileHandle
    private let writes = DispatchQueue(label: "synth.acp.write")
    private let reads = DispatchQueue(label: "synth.acp.read")
    private let errorReads = DispatchQueue(label: "synth.acp.stderr")

    init(executable: URL, arguments: [String], directory: URL?, environment: [String: String]?) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        diagnostics = errorPipe.fileHandleForReading
        self.process = process
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
    }

    func readMessages(
        _ receive: @escaping @Sendable (Envelope) async throws -> Void,
        ended: @escaping @Sendable ((any Error)?) async -> Void
    ) {
        Task.detached { [output, reads] in
            do {
                let decoder = JSONDecoder()
                var framer = LineFramer()
                while let chunk = try await Self.read(output, on: reads) {
                    for frame in try framer.push(chunk) {
                        try await receive(decoder.decode(Envelope.self, from: frame))
                    }
                }
                try framer.finish()
                await ended(nil)
            } catch {
                await ended(error)
            }
            try? output.close()
        }
    }

    func readDiagnostics(_ receive: @escaping @Sendable (Data) async -> Void) {
        Task.detached { [diagnostics, errorReads] in
            while let chunk = try? await Self.read(diagnostics, on: errorReads) {
                await receive(chunk)
            }
            try? diagnostics.close()
        }
    }

    private static func read(_ handle: FileHandle, on queue: DispatchQueue) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try read(handle) }) }
        }
    }

    private static func read(_ handle: FileHandle) throws -> Data? {
        // FileHandle's sized reads may wait to fill the buffer on a pipe.
        var bytes = Data(count: 64 * 1024)
        let count = bytes.withUnsafeMutableBytes { buffer in
            var readCount: Int
            repeat {
                readCount = Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            } while readCount == -1 && errno == EINTR
            return readCount
        }
        if count == 0 { return nil }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        bytes.removeLast(bytes.count - count)
        return bytes
    }

    func write(_ envelope: Envelope, completed: @escaping @Sendable ((any Error)?) -> Void) throws {
        var frame = try JSONEncoder().encode(envelope)
        guard frame.count <= LineFramer.maximumBytes else { throw LineFramer.Failure.oversized }
        frame.append(10)
        let data = frame
        writes.async { [input] in
            do {
                try input.write(contentsOf: data)
                completed(nil)
            } catch {
                completed(error)
            }
        }
    }

    func closeInput() {
        writes.async { [input] in try? input.close() }
    }

    func shutDown() async {
        closeInput()
        await Task.detached { [process] in
            let clock = ContinuousClock()
            let gracefulDeadline = clock.now + .seconds(2)
            while process.isRunning, clock.now < gracefulDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard process.isRunning else { return }
            process.terminate()
            let terminateDeadline = clock.now + .seconds(1)
            while process.isRunning, clock.now < terminateDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }.value
    }
}
