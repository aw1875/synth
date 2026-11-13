import Darwin
import Foundation

enum LoginEnvironment {
    private static let marker = Data("\0synth-login-environment\0".utf8)
    private static let limit = 1024 * 1024

    static func load() async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let inherited = ProcessInfo.processInfo.environment
                continuation.resume(returning: capture(inherited) ?? inherited)
            }
        }
    }

    private static func capture(_ inherited: [String: String]) -> [String: String]? {
        let shell = inherited["SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        guard shell.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [
            "-l", "-c", "/usr/bin/printf '\\000synth-login-environment\\000'; exec /usr/bin/env -0"
        ]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let handle = pipe.fileHandleForReading
        defer {
            try? handle.close()
            if process.isRunning { process.terminate() }
        }
        guard let output = read(handle), let start = output.range(of: marker)?.upperBound,
              output.last == 0 else { return nil }
        var environment = inherited
        for item in output[start...].split(separator: 0) {
            guard let equal = item.firstIndex(of: 61),
                  let name = String(bytes: item[..<equal], encoding: .utf8),
                  !["PWD", "OLDPWD", "SHLVL", "_"].contains(name),
                  let value = String(bytes: item[item.index(after: equal)...], encoding: .utf8) else { continue }
            if inherited[name] != nil, ["SYNTH_", "XDG_", "OPENAI_", "OLLAMA_"].contains(where: name.hasPrefix) {
                continue
            }
            environment[name] = value
        }
        return environment
    }

    private static func read(_ handle: FileHandle) -> Data? {
        let deadline = ContinuousClock.now + .seconds(3)
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while ContinuousClock.now < deadline, output.count < limit {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready == -1 && errno == EINTR) { continue }
            guard ready > 0 else { return nil }
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count == 0 { return output }
            guard count > 0 else { return nil }
            output.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }
}
