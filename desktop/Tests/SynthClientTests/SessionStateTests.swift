import Foundation
@testable import SynthClient
import SynthProtocol
import Testing

@Test func reducesZigGeneratedTranscript() throws {
    let source = try #require(
        Bundle.module.url(forResource: "stream", withExtension: "jsonl", subdirectory: "Fixtures")
    )
    var framer = LineFramer()
    let frames = try framer.push(Data(contentsOf: source)).map {
        try JSONDecoder().decode(Envelope.self, from: $0)
    }
    let snapshot = try frames[0].parameters(Synth.Snapshot.self)
    var state = SessionState()
    state.replace(with: snapshot)
    #expect(state.messages.map(\.text) == ["Hello"])
    for frame in frames[1...2] {
        let update = try frame.parameters(Synth.StreamUpdate.self)
        state.append(update.stream)
    }
    #expect(state.stream?.text == "Héllo")
    #expect(state.stream?.closed == true)

    let final = try frames[3].parameters(Synth.MessageUpdate.self)
    state.update(final.message, appended: true)
    #expect(state.stream == nil)
    #expect(state.messages.map(\.text) == ["Hello", "Héllo"])
    state.update(final.message, appended: false)
    #expect(state.messages.count == 2)
    state.update(try frames[4].parameters(Synth.StatusUpdate.self).status)
    #expect(state.status?.finished == 1)
    #expect(state.status?.isBusy == false)

    state.replace(with: snapshot)
    #expect(state.messages.count == 1)
    #expect(state.stream == nil)
}

@Test(.timeLimit(.minutes(1)))
func rejectsIncompatibleEngineAndKeepsDiagnosticsBounded() async throws {
    let script = #"""
    IFS= read -r handshake
    /usr/bin/awk 'BEGIN {for(i=0;i<9000;i++)printf "x"; print "fixture stderr"}' >&2
    printf '%s%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"synth"},' \
      '"_meta":{"synth":{"protocol":99}},"futureField":true}}'
    /bin/cat > /dev/null
    """#
    let client = SynthClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    do {
        try await client.connect()
        Issue.record("The incompatible engine was accepted")
    } catch let error as SynthClient.Failure {
        guard case .incompatible(acp: 1, synth: 99) = error else {
            Issue.record("Unexpected handshake failure: \(error)")
            return
        }
    }
    if case .failed = await client.connectionState {} else { Issue.record("Expected a failed connection") }
    let diagnostics = try await wait {
        let text = await client.diagnostics
        return text.hasSuffix("fixture stderr\n") ? text : nil
    }
    #expect(diagnostics.utf8.count <= 8192)
}

@Test(.timeLimit(.minutes(1)))
func disconnectFailsAnOutstandingRequestAndRetainsTranscript() async throws {
    let fixture = try #require(
        Bundle.module.url(forResource: "stream", withExtension: "jsonl", subdirectory: "Fixtures")
    )
    let script = #"""
    IFS= read -r handshake
    printf '%s%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"synth"},' \
      '"_meta":{"synth":{"protocol":2}}}}'
    IFS= read -r open
    /bin/cat "$1"
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"ses_fixture"}}'
    IFS= read -r prompt
    """#
    let client = SynthClient(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, "fixture", fixture.path]
    )
    try await client.connect()
    _ = try await client.newSession(cwd: "/fixture")
    do {
        _ = try await client.prompt("A prompt with no reply", in: "ses_fixture")
        Issue.record("The prompt succeeded after its engine exited")
    } catch SynthClient.Failure.disconnected {}
    _ = try await wait {
        if case .failed = await client.connectionState { return true }
        return nil
    }
    #expect(await client.sessions["ses_fixture"]?.messages.map(\.text) == ["Hello", "Héllo"])
    #expect(await client.sessions["ses_fixture"]?.stream == nil)
}
