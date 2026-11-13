public enum Interaction: Equatable, Identifiable, Sendable {
    case permission(RequestID, Permission)
    case question(RequestID, Question)

    public var id: RequestID {
        switch self {
        case .permission(let id, _), .question(let id, _): id
        }
    }

    public var sessionID: String {
        switch self {
        case .permission(_, let permission): permission.sessionId
        case .question(_, let question): question.sessionId
        }
    }

    public struct Permission: Decodable, Equatable, Sendable {
        public struct Tool: Decodable, Equatable, Sendable {
            public let toolCallId: String
            public let title: String?
            public let kind: String?
            public let rawInput: JSONValue?
        }

        public struct Option: Decodable, Equatable, Identifiable, Sendable {
            public let optionId: String
            public let name: String
            public let kind: String

            public var id: String { optionId }
        }

        public let sessionId: String
        public let toolCall: Tool
        public let options: [Option]
    }

    public struct Question: Decodable, Equatable, Sendable {
        public struct Schema: Decodable, Equatable, Sendable {
            public struct Field: Decodable, Equatable, Sendable {
                public struct Choice: Decodable, Equatable, Sendable {
                    public let `const`: String
                    public let title: String
                }

                public let type: String
                public let title: String?
                public let oneOf: [Choice]?
            }

            public let type: String
            public let properties: [String: Field]
            public let required: [String]
        }

        public let sessionId: String
        public let toolCallId: String?
        public let mode: String
        public let message: String
        public let requestedSchema: Schema
    }
}
