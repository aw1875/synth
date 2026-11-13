import Foundation
import SynthClient
import SynthProtocol
import Testing

private struct TimedOut: Error {}

private struct Fixture {
    let root: URL
    let engine: URL
    let environment: [String: String]
    let first: URL
    let second: URL

    init(engine: String, provider: String) throws {
        root = URL(fileURLWithPath: "/tmp/synth-acp-\(UUID().uuidString.prefix(12))")
        self.engine = URL(fileURLWithPath: engine)
        first = root.appending(path: "First Project")
        second = root.appending(path: "Second Project")
        let config = root.appending(path: "config/synth")
        do {
            for directory in [first, second, config, root.appending(path: "data")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data(#"{"auto_approve_safe_commands":false,"approvals":"ask","max_stall_ms":5000}"#.utf8)
                .write(to: config.appending(path: "config.json"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": root.appending(path: "config").path,
            "XDG_DATA_HOME": root.appending(path: "data").path,
            "SYNTH_SOCKET_DIR": root.appending(path: "sockets").path,
            "SYNTH_PROVIDER": "openai-compat",
            "OPENAI_BASE_URL": provider
        ]
    }

    func client() -> SynthClient { SynthClient(executable: engine, directory: root, environment: environment) }
}

func wait<Value: Sendable>(
    for value: @Sendable () async -> Value?
) async throws -> Value {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(6)
    while clock.now < deadline {
        if let result = await value() { return result }
        try await Task.sleep(for: .milliseconds(15))
    }
    throw TimedOut()
}

private func interaction(in session: String, from client: SynthClient) async throws -> Interaction {
    try await wait { await client.interactions.values.first { $0.sessionID == session } }
}

private func turn(_ text: String, session: String, client: SynthClient) -> Task<ACP.Prompted, any Error> {
    Task { try await client.prompt(text, in: session) }
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["SYNTH_TEST_ENGINE"] != nil, "Run the fake provider harness"),
    .timeLimit(.minutes(1))
)
func twoSessionsThroughRealRouter() async throws {
    let env = ProcessInfo.processInfo.environment
    let engine = try #require(env["SYNTH_TEST_ENGINE"])
    let provider = try #require(env["SYNTH_TEST_PROVIDER"])
    let fixture = try Fixture(engine: engine, provider: provider)
    let client = fixture.client()
    let guest = fixture.client()
    do {
        try await runScenario(fixture: fixture, client: client, guest: guest)
    } catch {
        await guest.disconnect()
        await client.disconnect()
        try? FileManager.default.removeItem(at: fixture.root)
        throw error
    }
    await guest.disconnect()
    await client.disconnect()
    try FileManager.default.removeItem(at: fixture.root)
}

private func runScenario(fixture: Fixture, client: SynthClient, guest: SynthClient) async throws {
    let initReply = try await client.connect()
    #expect(initReply.metadata?.synth?.protocol == ACP.synthVersion)
    let first = try #require(try await client.newSession(cwd: fixture.first.path).sessionId)
    let second = try #require(try await client.newSession(cwd: fixture.second.path).sessionId)
    #expect(first != second)
    let firstRoot = try #require(await client.sessions[first]?.status?.root)
    let actualDirectory = URL(fileURLWithPath: firstRoot, isDirectory: true).resolvingSymlinksInPath()
    let expectedDirectory = URL(fileURLWithPath: fixture.first.path, isDirectory: true).resolvingSymlinksInPath()
    #expect(actualDirectory.path == expectedDirectory.path)

    try await verifyApprovals(fixture: fixture, client: client, first: first, second: second)

    let choice = turn("ask fixture choice", session: first, client: client)
    let question = try await interaction(in: first, from: client)
    let steering = turn("steering fixture", session: first, client: client)
    _ = try await wait {
        await client.sessions[first]?.status?.steering.contains("steering fixture") == true ? true : nil
    }
    try await client.answer(question.id, fields: ["answer": "Blue"])
    #expect(try await choice.value.stopReason == "end_turn")
    #expect(try await steering.value.stopReason == "end_turn")
    let messages = await client.sessions[first]?.messages ?? []
    #expect(messages.contains { $0.text == "steering fixture" })
    #expect(messages.contains { $0.role == "tool" && $0.text.contains("Blue") })
    #expect(await client.sessions[first]?.stream == nil)

    try await guest.connect()
    _ = try await guest.loadSession(first, cwd: fixture.first.path)
    let shared = turn("shared fixture question", session: first, client: client)
    let hostQuestion = try await interaction(in: first, from: client)
    let guestQuestion = try await interaction(in: first, from: guest)
    try await guest.answer(guestQuestion.id, fields: ["answer": "the guest answered"])
    #expect(try await shared.value.stopReason == "end_turn")
    _ = try await wait { await client.interactions[hostQuestion.id] == nil ? true : nil }

    let cancelled = turn("cancel fixture question", session: second, client: client)
    let pending = try await interaction(in: second, from: client)
    try await client.cancelTurn(in: second)
    #expect(try await cancelled.value.stopReason == "cancelled")
    _ = try await wait { await client.interactions[pending.id] == nil ? true : nil }
    let listed = try await client.listSessions().sessions
    #expect(Set(listed.map(\.sessionId)) == [first, second])
    await client.disconnect()

    #expect(try await guest.prompt("still attached", in: first).stopReason == "end_turn")
    let failures = try await client.reconnect()
    #expect(failures.isEmpty)
    let reloaded = await client.sessions[first]?.messages ?? []
    #expect(reloaded.filter { $0.text == "approve fixture write" }.count == 1)
    #expect(reloaded.contains { $0.text.contains("the guest answered") })
    #expect(reloaded.contains { $0.role == "assistant" && $0.text == "Fixture complete: still attached" })
    #expect(await client.interactions.isEmpty)
}

private func verifyApprovals(
    fixture: Fixture, client: SynthClient, first: String, second: String
) async throws {
    let approve = turn("approve fixture write", session: first, client: client)
    let deny = turn("deny fixture write", session: second, client: client)
    let firstRequest = try await interaction(in: first, from: client)
    let secondRequest = try await interaction(in: second, from: client)
    guard case .permission(_, let permission) = firstRequest,
          case .permission(_, let rejection) = secondRequest else {
        Issue.record("Expected two permission requests")
        return
    }
    #expect(firstRequest.id != secondRequest.id)
    let allow = try #require(permission.options.first { $0.kind == "allow_once" })
    let reject = try #require(rejection.options.first { $0.kind == "reject_once" })
    try await client.decide(secondRequest.id, optionID: reject.optionId)
    #expect(try await deny.value.stopReason == "end_turn")
    #expect(await client.interactions[firstRequest.id] != nil)
    try await client.decide(firstRequest.id, optionID: allow.optionId)
    #expect(try await approve.value.stopReason == "end_turn")
    #expect(FileManager.default.fileExists(atPath: fixture.first.appending(path: "approved.txt").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.second.appending(path: "denied.txt").path))

    let always = turn("always allow fixture command", session: first, client: client)
    let alwaysRequest = try await interaction(in: first, from: client)
    guard case .permission(_, let command) = alwaysRequest else {
        Issue.record("Expected command approval")
        return
    }
    let alwaysOption = try #require(command.options.first { $0.kind == "allow_always" })
    try await client.decide(alwaysRequest.id, optionID: alwaysOption.optionId)
    #expect(try await always.value.stopReason == "end_turn")
}
