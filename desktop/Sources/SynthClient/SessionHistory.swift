import SynthProtocol

extension SynthClient {
    public func rename(_ title: String, in sessionID: String) async throws {
        try requireConnected()
        let request = Synth.Rename(sessionID: sessionID, title: title)
        _ = try await call("_synth/rename", request, as: ACP.Empty.self)
    }

    public func history(before sequence: UInt64, in sessionID: String) async throws -> [Synth.Message] {
        try requireConnected()
        let request = Synth.HistoryPage(sessionID: sessionID, before: sequence, limit: 50)
        return try await call("_synth/page_history", request, as: [Synth.Message].self)
    }

    public func thinking(sequence: UInt64, in sessionID: String) async throws -> String {
        try requireConnected()
        let request = Synth.MessageBody(sessionID: sessionID, sequence: sequence)
        return try await call("_synth/load_thinking", request, as: String.self)
    }

    public func toolResult(sequence: UInt64, call index: Int, in sessionID: String) async throws -> String {
        try requireConnected()
        let request = Synth.MessageBody(sessionID: sessionID, sequence: sequence, call: index)
        return try await call("_synth/load_tool_result", request, as: String.self)
    }
}
