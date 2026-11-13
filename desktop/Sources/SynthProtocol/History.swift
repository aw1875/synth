extension Synth {
    public struct Rename: Encodable, Sendable {
        public let sessionId: String
        public let title: String

        public init(sessionID: String, title: String) {
            sessionId = sessionID
            self.title = title
        }
    }

    public struct HistoryPage: Encodable, Sendable {
        public let sessionId: String
        public let beforeSequence: UInt64
        public let limit: Int

        private enum CodingKeys: String, CodingKey {
            case sessionId, limit
            case beforeSequence = "before_seq"
        }

        public init(sessionID: String, before: UInt64, limit: Int) {
            sessionId = sessionID
            beforeSequence = before
            self.limit = limit
        }
    }

    public struct MessageBody: Encodable, Sendable {
        public let sessionId: String
        public let seq: UInt64
        public let call: Int?

        public init(sessionID: String, sequence: UInt64, call: Int? = nil) {
            sessionId = sessionID
            seq = sequence
            self.call = call
        }
    }
}
