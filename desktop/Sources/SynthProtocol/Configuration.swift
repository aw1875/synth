extension ACP {
    public struct SetMode: Encodable, Sendable {
        public let sessionId: String
        public let modeId: String

        public init(sessionID: String, modeID: String) {
            sessionId = sessionID
            modeId = modeID
        }
    }

    public struct SetConfiguration: Encodable, Sendable {
        private struct ModelMetadata: Encodable, Sendable {
            struct Selection: Encodable, Sendable {
                let provider: String
            }

            let synth: Selection
        }

        public let sessionId: String
        public let configId: String
        public let value: String
        private let metadata: ModelMetadata?

        private enum CodingKeys: String, CodingKey {
            case sessionId, configId, value
            case metadata = "_meta"
        }

        public init(sessionID: String, configID: String, value: String, provider: String? = nil) {
            sessionId = sessionID
            configId = configID
            self.value = value
            metadata = provider.map { .init(synth: .init(provider: $0)) }
        }
    }
}

extension Synth {
    public struct Model: Decodable, Equatable, Identifiable, Sendable {
        public let name: String
        public let provider: String
        public let providerID: String
        public let efforts: [String]
        public let effort: String

        public var id: String { "\(providerID):\(name)" }

        private enum CodingKeys: String, CodingKey {
            case name, provider, efforts, effort
            case providerID = "provider_id"
        }
    }

    public struct Models: Decodable, Equatable, Sendable {
        public let offered: [Model]
        public let pending: Int
    }

    public struct ModelsUpdate: Decodable, Sendable {
        public let sessionId: String
        public let models: Models
    }
}
