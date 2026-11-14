import Foundation

public enum RequestID: Hashable, Sendable, Codable {
    case number(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public struct RPCError: Codable, Equatable, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }
}

public struct Envelope: Codable, Sendable {
    public private(set) var jsonrpc = "2.0"
    public let id: RequestID?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: RPCError?

    private init(id: RequestID?, method: String?, params: JSONValue?, result: JSONValue?, error: RPCError?) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public static func call(_ method: String, id: RequestID? = nil, params: some Encodable) throws -> Self {
        try .init(id: id, method: method, params: JSONValue(encoding: params), result: nil, error: nil)
    }

    public static func reply(_ id: RequestID, result: some Encodable) throws -> Self {
        try .init(id: id, method: nil, params: nil, result: JSONValue(encoding: result), error: nil)
    }

    public static func failure(_ id: RequestID, _ error: RPCError) -> Self {
        .init(id: id, method: nil, params: nil, result: nil, error: error)
    }

    public func parameters<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try (params ?? .object([:])).decode(type)
    }
}

public struct LineFramer: Sendable {
    public static let maximumBytes = 16 * 1024 * 1024

    public enum Failure: LocalizedError {
        case oversized
        case incomplete

        public var errorDescription: String? {
            switch self {
            case .oversized: "Synth sent a frame larger than the 16 MiB protocol limit."
            case .incomplete: "Synth closed its output in the middle of a frame."
            }
        }
    }

    private var partial = Data()
    private let limit: Int

    public init(limit: Int = Self.maximumBytes) {
        self.limit = limit
    }

    public mutating func push(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            guard end - start <= limit - partial.count else { throw Failure.oversized }
            partial.append(contentsOf: data[start..<end])
            guard newline != nil else { break }
            if partial.last == 13 { partial.removeLast() }
            if !partial.isEmpty { frames.append(partial) }
            partial = Data()
            start = end + 1
        }
        return frames
    }

    public func finish() throws {
        if !partial.isEmpty { throw Failure.incomplete }
    }
}
