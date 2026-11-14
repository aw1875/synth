import SynthProtocol

extension SynthClient {
    public struct Activity: Equatable, Sendable {
        public let title: String?
        public let busy: Bool
        public let awaitingInput: Bool
        public let finished: UInt64
        public let failed: Bool
    }

    public struct ViewState: Sendable {
        public let connection: ConnectionState
        public let session: SessionState?
        public let interactions: [Interaction]
        public let activity: [String: Activity]
    }

    public func viewState(for sessionID: String?) -> ViewState {
        let waiting = Set(interactions.values.map(\.sessionID))
        let activity = sessions.reduce(into: [String: Activity]()) { result, entry in
            let (identifier, session) = entry
            result[identifier] = Activity(
                title: session.status?.title,
                busy: connectionState == .connected && session.failure == nil && session.status?.isBusy == true,
                awaitingInput: waiting.contains(identifier),
                finished: session.status?.finished ?? 0,
                failed: session.failure != nil
            )
        }
        return ViewState(
            connection: connectionState,
            session: sessionID.flatMap { sessions[$0] },
            interactions: interactions.values.filter { $0.sessionID == sessionID }
                .sorted { String(describing: $0.id) < String(describing: $1.id) },
            activity: activity
        )
    }
}
