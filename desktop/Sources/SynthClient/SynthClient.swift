import Foundation
import SynthProtocol

public actor SynthClient {
    private let executable: URL
    private let arguments: [String]
    private let directory: URL?
    private let environment: [String: String]?
    private var transport: ProcessTransport?
    var generation = UUID()
    private var nextID: Int64 = 1
    private var pending: [RequestID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var workingDirectories: [String: String] = [:]
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var diagnosticBytes = Data()
    var modelUpdates: [String: UInt64] = [:]

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var sessions: [String: SessionState] = [:]
    public private(set) var interactions: [RequestID: Interaction] = [:]
    public var diagnostics: String {
        String(bytes: diagnosticBytes, encoding: .utf8) ?? "Synth emitted non-UTF-8 diagnostics."
    }

    public init(
        executable: URL,
        arguments: [String] = ["acp"],
        directory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }

    deinit {
        transport?.closeInput()
        for waiter in pending.values { waiter.resume(throwing: Failure.disconnected) }
        for subscriber in subscribers.values { subscriber.finish() }
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield()
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func changed() {
        for subscriber in subscribers.values { subscriber.yield() }
    }

    @discardableResult
    public func connect() async throws -> ACP.Initialized {
        guard transport == nil, connectionState != .disconnecting else { throw Failure.alreadyConnected }
        let generation = UUID()
        self.generation = generation
        diagnosticBytes.removeAll()
        connectionState = .connecting
        changed()
        do {
            let transport = try ProcessTransport(
                executable: executable, arguments: arguments, directory: directory, environment: environment
            )
            self.transport = transport
            transport.readMessages({ [weak self] envelope in
                try await self?.receive(envelope, generation: generation)
            }, ended: { [weak self] error in
                await self?.ended(error, generation: generation)
            })
            transport.readDiagnostics { [weak self] data in
                await self?.appendDiagnostics(data, generation: generation)
            }

            let timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.handshakeTimedOut(generation)
            }
            defer { timer.cancel() }
            let reply = try await call("initialize", ACP.Initialize(), as: ACP.Initialized.self)
            guard reply.protocolVersion == ACP.version, reply.metadata?.synth?.protocol == ACP.synthVersion else {
                throw Failure.incompatible(acp: reply.protocolVersion, synth: reply.metadata?.synth?.protocol)
            }
            guard self.generation == generation, connectionState == .connecting else {
                throw Failure.disconnected
            }
            connectionState = .connected
            changed()
            return reply
        } catch {
            if self.generation == generation, connectionState == .connecting {
                await finish(.failed(error.localizedDescription), cause: error)
            }
            throw error
        }
    }

    private func handshakeTimedOut(_ generation: UUID) async {
        guard self.generation == generation, connectionState == .connecting else { return }
        let error = Failure.handshakeTimedOut
        await finish(.failed(error.localizedDescription), cause: error)
    }

    public func reconnect() async throws -> [String: String] {
        let restore = workingDirectories
        try await connect()
        var failures: [String: String] = [:]
        for (sessionID, cwd) in restore.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try await loadSession(sessionID, cwd: cwd)
            } catch {
                failures[sessionID] = error.localizedDescription
            }
        }
        return failures
    }

    public func disconnect() async {
        guard connectionState != .disconnecting else { return }
        await finish(.disconnected, cause: Failure.disconnected)
    }
}

extension SynthClient {
    public func newSession(cwd: String) async throws -> ACP.SessionOpened {
        try requireConnected()
        let reply = try await call("session/new", ACP.Open(cwd: cwd), as: ACP.SessionOpened.self)
        guard let id = reply.sessionId else { throw Failure.invalidResponse("missing session ID") }
        workingDirectories[id] = cwd
        return reply
    }

    public func loadSession(_ sessionID: String, cwd: String) async throws -> ACP.SessionOpened {
        try requireConnected()
        do {
            let reply = try await call(
                "session/load", ACP.Open(cwd: cwd, sessionID: sessionID), as: ACP.SessionOpened.self
            )
            workingDirectories[sessionID] = cwd
            return reply
        } catch {
            markSessionFailed(sessionID, error: error)
            throw error
        }
    }

    public func listSessions(cwd: String? = nil, cursor: String? = nil) async throws -> ACP.SessionList {
        try requireConnected()
        return try await call("session/list", ACP.List(cwd: cwd, cursor: cursor), as: ACP.SessionList.self)
    }

    func forgetSession(_ sessionID: String) {
        workingDirectories.removeValue(forKey: sessionID)
        sessions.removeValue(forKey: sessionID)
        modelUpdates.removeValue(forKey: sessionID)
        interactions = interactions.filter { $0.value.sessionID != sessionID }
        changed()
    }

    public func prompt(_ text: String, in sessionID: String) async throws -> ACP.Prompted {
        try requireConnected()
        do {
            return try await call("session/prompt", ACP.Prompt(sessionID: sessionID, text: text), as: ACP.Prompted.self)
        } catch let error as RPCError where error.code == -32603 &&
            ["the session's agent stopped", "no such session"].contains(error.message) {
            markSessionFailed(sessionID, error: error)
            throw error
        }
    }

    public func cancelTurn(in sessionID: String) async throws {
        try requireConnected()
        try await write(Envelope.call("session/cancel", params: ACP.SessionRef(sessionID)))
    }

    public func decide(_ id: RequestID, optionID: String) async throws {
        guard let interaction = interactions[id] else { return }
        guard case .permission(_, let permission) = interaction,
              permission.options.contains(where: { $0.optionId == optionID }) else {
            throw Failure.invalidAnswer
        }
        try await resolve(id, with: ["outcome": ["outcome": "selected", "optionId": optionID]])
    }

    public func answer(_ id: RequestID, fields: [String: String]) async throws {
        guard let interaction = interactions[id] else { return }
        guard case .question(_, let question) = interaction,
              fields.values.contains(where: { !$0.isEmpty }),
              question.requestedSchema.required.allSatisfy({ fields[$0]?.isEmpty == false }),
              fields.allSatisfy({ key, value in
                  guard let field = question.requestedSchema.properties[key], field.type == "string" else {
                      return false
                  }
                  return field.oneOf?.contains(where: { $0.const == value }) ?? true
              }) else { throw Failure.invalidAnswer }
        try await resolve(id, with: JSONValue.object([
            "action": .string("accept"),
            "content": .object(fields.mapValues(JSONValue.string))
        ]))
    }

    public func declineQuestion(_ id: RequestID) async throws {
        guard let interaction = interactions[id] else { return }
        guard case .question = interaction else { throw Failure.invalidAnswer }
        try await resolve(id, with: ["action": "decline"])
    }

    func requireConnected() throws {
        guard connectionState == .connected else { throw Failure.disconnected }
    }

    func call<Result: Decodable>(
        _ method: String, _ params: some Encodable, as type: Result.Type
    ) async throws -> Result {
        guard let transport else { throw Failure.disconnected }
        try Task.checkCancellation()
        let id = RequestID.number(nextID)
        nextID += 1
        let envelope = try Envelope.call(method, id: id, params: params)
        let generation = self.generation
        let value: JSONValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try transport.write(envelope) { [weak self] error in
                        if let error {
                            Task { await self?.ended(error, generation: generation) }
                        }
                    }
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.withdraw(id, generation: generation) }
        }
        return try value.decode(type)
    }

    private func withdraw(_ id: RequestID, generation: UUID) async {
        guard generation == self.generation, let waiter = pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        try? await write(Envelope.call("$/cancel_request", params: ACP.CancelRequest(id)))
    }

    private func resolve(_ id: RequestID, with result: some Encodable) async throws {
        let envelope = try Envelope.reply(id, result: result)
        interactions.removeValue(forKey: id)
        changed()
        try await write(envelope)
    }

    private func write(_ envelope: Envelope) async throws {
        guard let transport else { throw Failure.disconnected }
        let generation = self.generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try transport.write(envelope) { [weak self] error in
                    if let error {
                        continuation.resume(throwing: error)
                        Task { await self?.ended(error, generation: generation) }
                    } else {
                        continuation.resume()
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

extension SynthClient {
    private func receive(_ envelope: Envelope, generation: UUID) async throws {
        guard generation == self.generation, transport != nil else { return }
        guard envelope.jsonrpc == "2.0" else { throw Failure.invalidResponse("JSON-RPC version must be 2.0") }
        guard let method = envelope.method else {
            guard let id = envelope.id, let waiter = pending.removeValue(forKey: id) else { return }
            if let error = envelope.error {
                waiter.resume(throwing: error)
            } else if let result = envelope.result {
                waiter.resume(returning: result)
            } else {
                waiter.resume(throwing: Failure.invalidResponse("missing result or error"))
            }
            return
        }
        if let id = envelope.id {
            try await receiveRequest(method, id: id, envelope: envelope)
        } else {
            try receiveNotification(method, envelope: envelope)
        }
    }

    private func receiveRequest(_ method: String, id: RequestID, envelope: Envelope) async throws {
        switch method {
        case "session/request_permission":
            interactions[id] = .permission(id, try envelope.parameters(Interaction.Permission.self))
        case "elicitation/create":
            let question = try envelope.parameters(Interaction.Question.self)
            guard question.mode == "form", question.requestedSchema.type == "object",
                  question.requestedSchema.properties.values.allSatisfy({ $0.type == "string" }) else {
                try await write(.failure(id, .init(code: -32602, message: "Unsupported elicitation form")))
                return
            }
            interactions[id] = .question(id, question)
        default:
            try await write(.failure(id, .init(code: -32601, message: "Unsupported client method: \(method)")))
            return
        }
        changed()
    }

    private func receiveNotification(_ method: String, envelope: Envelope) throws {
        switch method {
        case "$/cancel_request":
            interactions.removeValue(forKey: try envelope.parameters(ACP.CancelRequest.self).requestId)
        case "_synth/snapshot":
            let event = try envelope.parameters(Synth.Snapshot.self)
            sessions[event.sessionId, default: .init()].replace(with: event)
        case "_synth/appended", "_synth/updated":
            let event = try envelope.parameters(Synth.MessageUpdate.self)
            sessions[event.sessionId, default: .init()].update(event.message, appended: method == "_synth/appended")
        case "_synth/stream":
            let event = try envelope.parameters(Synth.StreamUpdate.self)
            sessions[event.sessionId, default: .init()].append(event.stream)
        case "_synth/status":
            let event = try envelope.parameters(Synth.StatusUpdate.self)
            sessions[event.sessionId, default: .init()].update(event.status)
        case "_synth/models_updated":
            let event = try envelope.parameters(Synth.ModelsUpdate.self)
            modelUpdates[event.sessionId, default: 0] += 1
            sessions[event.sessionId, default: .init()].update(event.models)
        case "_synth/notice":
            let event = try envelope.parameters(Synth.Notice.self)
            sessions[event.sessionId, default: .init()].notice(event.text)
        case "_synth/session_stopped":
            let event = try envelope.parameters(ACP.SessionRef.self)
            markSessionFailed(event.sessionId, error: RPCError(code: -32603, message: "The session's engine stopped."))
            return
        default:
            return
        }
        changed()
    }

    func acceptModels(_ models: Synth.Models, sessionID: String, generation: UUID, revision: UInt64) {
        guard generation == self.generation, connectionState == .connected,
              revision == modelUpdates[sessionID, default: 0] else { return }
        sessions[sessionID, default: .init()].update(models)
        changed()
    }

    private func markSessionFailed(_ sessionID: String, error: any Error) {
        sessions[sessionID, default: .init()].disconnect(error.localizedDescription)
        interactions = interactions.filter { $0.value.sessionID != sessionID }
        changed()
    }

    private func appendDiagnostics(_ data: Data, generation: UUID) {
        guard generation == self.generation else { return }
        diagnosticBytes.append(data)
        if diagnosticBytes.count > 8192 { diagnosticBytes = Data(diagnosticBytes.suffix(8192)) }
    }

    private func ended(_ error: (any Error)?, generation: UUID) async {
        guard generation == self.generation, transport != nil, connectionState != .disconnecting else { return }
        let message = error?.localizedDescription ?? "Synth closed its connection."
        await finish(.failed(message), cause: error ?? Failure.disconnected)
    }

    private func finish(_ finalState: ConnectionState, cause: any Error) async {
        let connection = transport
        transport = nil
        connectionState = connection == nil ? finalState : .disconnecting
        interactions.removeAll()
        for waiter in pending.values { waiter.resume(throwing: cause) }
        pending.removeAll()
        let failure: String?
        if case .failed(let message) = finalState { failure = message } else { failure = nil }
        for id in sessions.keys { sessions[id]?.disconnect(failure) }
        changed()

        await connection?.shutDown()
        connectionState = finalState
        changed()
    }
}
