import SynthProtocol

extension SynthClient {
    public struct ViewState: Sendable {
        public let connection: ConnectionState
        public let session: SessionState?
        public let interactions: [Interaction]
    }

    public func viewState(for sessionID: String?) -> ViewState {
        ViewState(
            connection: connectionState,
            session: sessionID.flatMap { sessions[$0] },
            interactions: interactions.values.filter { $0.sessionID == sessionID }
                .sorted { String(describing: $0.id) < String(describing: $1.id) }
        )
    }
}
