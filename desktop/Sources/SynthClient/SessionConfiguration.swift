import SynthProtocol

extension SynthClient {
    public func fetchModels(in sessionID: String) async throws {
        try requireConnected()
        let revision = modelUpdates[sessionID, default: 0]
        let connection = generation
        let models = try await call("_synth/models", ACP.SessionRef(sessionID), as: Synth.Models.self)
        acceptModels(models, sessionID: sessionID, generation: connection, revision: revision)
    }

    public func setMode(_ modeID: String, in sessionID: String) async throws {
        try requireConnected()
        _ = try await call("session/set_mode", ACP.SetMode(sessionID: sessionID, modeID: modeID), as: ACP.Empty.self)
    }

    public func setModel(_ model: Synth.Model, in sessionID: String) async throws {
        try await setConfiguration("model", value: model.name, provider: model.providerID, in: sessionID)
    }

    public func setEffort(_ effort: String, in sessionID: String) async throws {
        try await setConfiguration("effort", value: effort, in: sessionID)
    }

    private func setConfiguration(
        _ option: String, value: String, provider: String? = nil, in sessionID: String
    ) async throws {
        try requireConnected()
        let request = ACP.SetConfiguration(sessionID: sessionID, configID: option, value: value, provider: provider)
        _ = try await call("session/set_config_option", request, as: ACP.Empty.self)
    }
}
