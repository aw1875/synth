import Foundation
import SynthProtocol
import Testing

@Test func fragmentedUTF8AndMultipleFrames() throws {
    var framer = LineFramer()
    let message = Data("{\"jsonrpc\":\"2.0\",\"id\":\"clé\",\"result\":{}}\r\n".utf8)
    let split = try #require(message.firstIndex(of: 0xC3)) + 1
    #expect(try framer.push(message.prefix(split)).isEmpty)
    let frames = try framer.push(message.suffix(from: split) + Data("{\"jsonrpc\":\"2.0\",\"id\":7}\n".utf8))
    let decoder = JSONDecoder()
    #expect(try frames.map { try decoder.decode(Envelope.self, from: $0).id } == [.string("clé"), .number(7)])
    try framer.finish()
}

@Test func oversizedAndIncompleteFrames() throws {
    var framer = LineFramer(limit: 4)
    #expect(try framer.push(Data("1234\n".utf8)) == [Data("1234".utf8)])
    _ = try framer.push(Data("123".utf8))
    #expect(throws: LineFramer.Failure.incomplete) { try framer.finish() }
    #expect(throws: LineFramer.Failure.oversized) { try framer.push(Data("45\n".utf8)) }
}
