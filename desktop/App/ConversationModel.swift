import AppKit
import Observation
import SynthClient
import SynthProtocol

@MainActor
@Observable
final class ConversationModel {
    private(set) var project: URL?
    private(set) var sessionID: String?
    private(set) var state: SessionState?
    private(set) var interactions: [Interaction] = []
    private(set) var recentSessions: [ACP.SessionInfo] = []
    private(set) var modes: [ACP.Mode] = []
    private(set) var connection: SynthClient.ConnectionState = .disconnected
    private(set) var isOpening = false
    private(set) var isUpdatingConfiguration = false
    private(set) var modelError: String?
    private(set) var isFetchingModels = false
    private var modelsRequested = false
    private var submitting = 0
    private var stopRequested = false
    private var client: SynthClient?
    private var observing: Task<Void, Never>?
    private var ownedSession: String?

    var draft = ""
    var error: String?

    var busy: Bool {
        submitting > 0 || (connection == .connected && state?.failure == nil && state?.status?.isBusy == true)
    }
    var canSwitch: Bool { !busy && !isOpening && !isUpdatingConfiguration && !isFetchingModels }
    var canSend: Bool {
        connection == .connected && sessionID != nil && !isOpening &&
            !isUpdatingConfiguration && state?.failure == nil &&
            state?.status?.providerMissing == false && !stopRequested &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canStop: Bool {
        connection == .connected && sessionID != nil && busy && !stopRequested && state?.failure == nil
    }
    var canConfigure: Bool { sessionID != nil && connection == .connected && canSwitch && state?.failure == nil }
    var loadingModels: Bool { isFetchingModels || (state?.models?.pending ?? 0) > 0 }

    func chooseProject() {
        guard canSwitch else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let directory = panel.url else { return }
                Task { await self?.openProject(directory) }
            }
        } else {
            panel.begin { [weak self] response in
                guard response == .OK, let directory = panel.url else { return }
                Task { await self?.openProject(directory) }
            }
        }
    }

    private func openProject(_ directory: URL) async {
        guard canSwitch else { return }
        let folder = directory.resolvingSymlinksInPath()
        await open(in: folder)
    }

    func open(_ stored: ACP.SessionInfo? = nil) async {
        guard let project else { return }
        await open(in: project, stored: stored)
    }

    private func open(in project: URL, stored: ACP.SessionInfo? = nil) async {
        guard canSwitch else { return }
        isOpening = true
        error = nil
        defer { isOpening = false }
        do {
            let client = try await connectedClient()
            let setup: ACP.SessionOpened
            let openedID: String
            if let stored {
                setup = try await client.loadSession(stored.id, cwd: stored.cwd)
                openedID = stored.id
            } else {
                setup = try await client.newSession(cwd: project.path)
                guard let identifier = setup.sessionId else {
                    throw SynthClient.Failure.invalidResponse("missing session ID")
                }
                openedID = identifier
            }
            let previous = ownedSession
            let closePrevious = state?.messages.isEmpty == true
            if self.project != project { recentSessions = [] }
            self.project = project
            sessionID = openedID
            ownedSession = stored == nil ? openedID : nil
            modes = setup.modes?.availableModes ?? []
            draft = ""
            modelError = nil
            modelsRequested = false
            await refresh(from: client)
            await refreshHistory()
            if let previous, previous != openedID, closePrevious {
                try await client.closeSession(previous)
            }
        } catch {
            self.error = error.localizedDescription
            if self.project == nil { self.project = project }
        }
    }

    func refreshHistory() async {
        guard let project, let client, connection == .connected else { return }
        do {
            recentSessions = try await client.listSessions(cwd: project.path).sessions
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reconnect() async {
        guard !isOpening else { return }
        guard let client, let sessionID else {
            await open()
            return
        }
        isOpening = true
        error = nil
        defer { isOpening = false }
        do {
            let setup: ACP.SessionOpened?
            if await client.connectionState == .connected, let project {
                setup = try await client.loadSession(sessionID, cwd: project.path)
            } else {
                let failures = try await client.reconnect()
                error = failures[sessionID]
                setup = nil
            }
            if let modes = setup?.modes?.availableModes { self.modes = modes }
            modelsRequested = false
            modelError = nil
            await refresh(from: client)
            await refreshHistory()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connectedClient() async throws -> SynthClient {
        let engine: SynthClient
        if let client {
            engine = client
        } else {
            let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/synth")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw SynthClient.Failure.invalidResponse("the bundled Synth engine is missing")
            }
            let environment = await LoginEnvironment.load()
            engine = SynthClient(
                executable: executable,
                directory: FileManager.default.homeDirectoryForCurrentUser,
                environment: environment
            )
            client = engine
            observe(engine)
        }
        if await engine.connectionState != .connected { try await engine.connect() }
        connection = .connected
        return engine
    }

    private func observe(_ client: SynthClient) {
        observing = Task { [weak self] in
            for await _ in await client.changes() {
                guard let self else { return }
                await refresh(from: client)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func refresh(from client: SynthClient) async {
        let identifier = sessionID
        let snapshot = await client.viewState(for: identifier)
        guard self.client === client, sessionID == identifier else { return }
        connection = snapshot.connection
        state = snapshot.session
        interactions = snapshot.interactions
        if state?.status?.isBusy != true && submitting == 0 { stopRequested = false }
    }

    func shutdown() async {
        observing?.cancel()
        await client?.disconnect()
    }

    func retryProvider() async {
        guard canSwitch, let client else { return }
        isOpening = true
        await client.disconnect()
        self.client = nil
        observing?.cancel()
        observing = nil
        let savedDraft = draft
        let stored = recentSessions.first { $0.id == sessionID }
        isOpening = false
        await open(stored)
        draft = savedDraft
    }

    func send() async {
        guard canSend, let client, let sessionID else { return }
        let text = draft
        draft = ""
        error = nil
        submitting += 1
        defer {
            submitting -= 1
            if submitting == 0 { stopRequested = false }
        }
        do {
            _ = try await client.prompt(text, in: sessionID)
        } catch {
            if draft.isEmpty { draft = text }
            self.error = error.localizedDescription
        }
        await refresh(from: client)
        await refreshHistory()
    }

    func stop() async {
        guard canStop, let client, let sessionID else { return }
        stopRequested = true
        do {
            try await client.cancelTurn(in: sessionID)
        } catch {
            stopRequested = false
            self.error = error.localizedDescription
        }
    }
}

extension ConversationModel {
    var hasRequestedModels: Bool { modelsRequested }

    func fetchModels() async {
        guard canConfigure, let client, let sessionID else { return }
        modelError = nil
        modelsRequested = true
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            try await client.fetchModels(in: sessionID)
        } catch {
            modelError = error.localizedDescription
        }
    }

    func selectMode(_ mode: ACP.Mode) async {
        await configure { try await $0.setMode(mode.id, in: $1) }
    }

    func selectModel(_ model: Synth.Model) async {
        await configure { try await $0.setModel(model, in: $1) }
    }

    func selectEffort(_ effort: String) async {
        await configure { try await $0.setEffort(effort, in: $1) }
    }

    private func configure(_ operation: (SynthClient, String) async throws -> Void) async {
        guard canConfigure, let client, let sessionID else { return }
        isUpdatingConfiguration = true
        defer { isUpdatingConfiguration = false }
        do {
            try await operation(client, sessionID)
            await refresh(from: client)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func decide(_ request: RequestID, option: String) async {
        await respond { try await $0.decide(request, optionID: option) }
    }

    func answer(_ request: RequestID, fields: [String: String]) async {
        await respond { try await $0.answer(request, fields: fields) }
    }

    func decline(_ request: RequestID) async {
        await respond { try await $0.declineQuestion(request) }
    }

    private func respond(_ operation: (SynthClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await operation(client)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
