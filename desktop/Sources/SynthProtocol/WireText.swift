/// Zig serializes byte slices that aren't valid UTF-8 as JSON arrays.
@propertyWrapper
public struct WireText: Decodable, Equatable, Sendable {
    public var wrappedValue: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            wrappedValue = text
        } else {
            let bytes = try container.decode([UInt8].self)
            // swiftlint:disable:next optional_data_string_conversion
            wrappedValue = String(decoding: bytes, as: UTF8.self)
        }
    }
}
