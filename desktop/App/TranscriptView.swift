import SwiftUI
import SynthProtocol
import Textual

enum TranscriptAnchor: Hashable {
    case message(UInt64)
    case tail
}

struct TranscriptView: View {
    let sessionID: String
    let messages: [Synth.Message]
    let stream: Synth.Stream?
    let notices: [String]
    let interactions: [Interaction]
    let model: ConversationModel
    @Binding var anchor: TranscriptAnchor?

    @State private var followsConversation = true
    @State private var userScrolling = false

    private struct Tail: Equatable {
        let sequence: UInt64?
        let stream: Synth.Stream?
        let notices: [String]
        let interactions: [RequestID]
    }

    private var tail: Tail {
        Tail(sequence: messages.last?.seq, stream: stream, notices: notices, interactions: interactions.map(\.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.hasOlderMessages {
                        Button("Load Earlier Messages") { Task { await model.loadOlder() } }
                            .disabled(model.loadingHistory.contains(sessionID))
                    }
                    ForEach(messages) { message in
                        TranscriptRow(message: message, sessionID: sessionID, model: model)
                            .id(TranscriptAnchor.message(message.seq))
                    }
                    if let stream {
                        if !stream.thinking.isEmpty { ReasoningText(text: stream.thinking) }
                        if !stream.text.isEmpty {
                            Text(stream.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    TranscriptNotices(notices: notices)
                    ForEach(interactions) { interaction in
                        InteractionCard(interaction: interaction, model: model)
                    }
                    Color.clear.frame(height: 1).id(TranscriptAnchor.tail).accessibilityHidden(true)
                }
                .scrollTargetLayout()
                .frame(maxWidth: 730, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollPosition(id: $anchor, anchor: .top)
            .onAppear {
                if let anchor, anchor != .tail {
                    followsConversation = false
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 100
            } action: { _, nearBottom in
                if nearBottom || userScrolling { followsConversation = nearBottom }
            }
            .onScrollPhaseChange { previous, phase, context in
                let trackingUser = phase == .interacting || phase == .decelerating
                userScrolling = trackingUser
                if trackingUser || previous == .interacting || previous == .decelerating {
                    followsConversation = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 100
                }
            }
            .onChange(of: tail) {
                if followsConversation { proxy.scrollTo(TranscriptAnchor.tail, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsConversation {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        proxy.scrollTo(TranscriptAnchor.tail, anchor: .bottom)
                        followsConversation = true
                    }
                    .buttonStyle(.bordered)
                    .labelStyle(.iconOnly)
                    .help("Jump to Latest")
                    .padding()
                }
            }
        }
    }
}

struct TranscriptNotices: View {
    let notices: [String]

    var body: some View {
        ForEach(notices.indices, id: \.self) { index in
            Label(notices[index], systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct TranscriptRow: View {
    let message: Synth.Message
    let sessionID: String
    let model: ConversationModel

    var body: some View {
        switch message.role {
        case "user":
            VStack(alignment: .leading, spacing: 6) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
            }
            .padding(13)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 490, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case "assistant":
            assistant
        case "summary":
            Text(message.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    private typealias BodyLoader = @MainActor () async throws -> String

    @ViewBuilder
    private var assistant: some View {
        if message.thinking?.isEmpty == false || message.thinkingBytes > 0 {
            ReasoningText(text: message.thinking ?? "", load: reasoningLoader)
        }
        if !message.text.isEmpty { CompletedMarkdown(text: message.text) }
        ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { entry in
            ToolRow(tool: entry.element, load: resultLoader(entry.element, index: entry.offset))
        }
    }

    private var reasoningLoader: BodyLoader? {
        guard message.thinkingBytes > (message.thinking?.utf8.count ?? 0) else { return nil }
        return { try await model.fullThinking(message, in: sessionID) }
    }

    private func resultLoader(_ tool: Synth.ToolCall, index: Int) -> BodyLoader? {
        guard tool.resultBytes > (tool.result?.utf8.count ?? 0) else { return nil }
        return { try await model.fullToolResult(sequence: message.seq, call: index, in: sessionID) }
    }
}

private struct CompletedMarkdown: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
}

private struct ReasoningText: View {
    let text: String
    var load: (@MainActor () async throws -> String)?

    var body: some View {
        DisclosureGroup("Reasoning") {
            ExpandableBody(preview: text, load: load)
                .padding(.vertical, 5)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct ToolRow: View {
    let tool: Synth.ToolCall
    let load: (@MainActor () async throws -> String)?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(tool.arguments).textSelection(.enabled)
                if let result = tool.result, !result.isEmpty || load != nil {
                    Divider()
                    ExpandableBody(preview: result, load: load)
                } else if load != nil {
                    ExpandableBody(preview: "", load: load)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            HStack {
                Label(tool.name, systemImage: "wrench")
                Spacer()
                Text(tool.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ExpandableBody: View {
    let preview: String
    let load: (@MainActor () async throws -> String)?
    @State private var full: String?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(full ?? preview)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.secondary) }
            if let load, full == nil {
                Button(loading ? "Loading…" : "Load Full Text") {
                    Task {
                        loading = true
                        defer { loading = false }
                        error = nil
                        do { full = try await load() } catch {
                            if !Task.isCancelled { self.error = error.localizedDescription }
                        }
                    }
                }
                .disabled(loading)
            }
        }
    }
}
