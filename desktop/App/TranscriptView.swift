import SwiftUI
import SynthProtocol
import Textual

struct TranscriptView: View {
    let messages: [Synth.Message]
    let stream: Synth.Stream?
    let notices: [String]
    let interactions: [Interaction]
    let model: ConversationModel

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
                    if messages.isEmpty && stream == nil && interactions.isEmpty {
                        ContentUnavailableView(
                            "Start a conversation",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Ask about your project or describe a change.")
                        )
                        .padding(.vertical, 30)
                    }
                    ForEach(messages) { message in
                        TranscriptRow(message: message)
                    }
                    if let stream {
                        if !stream.thinking.isEmpty { ReasoningText(text: stream.thinking) }
                        if !stream.text.isEmpty {
                            Text(stream.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(notices.indices, id: \.self) { index in
                        Label(notices[index], systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(interactions) { interaction in
                        InteractionCard(interaction: interaction, model: model)
                    }
                    Color.clear.frame(height: 1).id("tail").accessibilityHidden(true)
                }
                .frame(maxWidth: 730, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
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
                if followsConversation { proxy.scrollTo("tail", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsConversation {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        proxy.scrollTo("tail", anchor: .bottom)
                        followsConversation = true
                    }
                    .buttonStyle(.bordered)
                    .padding()
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let message: Synth.Message

    var body: some View {
        switch message.role {
        case "user":
            VStack(alignment: .leading, spacing: 6) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        case "assistant":
            if let thinking = message.thinking, !thinking.isEmpty { ReasoningText(text: thinking) }
            if !message.text.isEmpty { CompletedMarkdown(text: message.text) }
            ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, tool in
                ToolRow(tool: tool)
            }
        case "summary":
            Text(message.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        default:
            EmptyView()
        }
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

    var body: some View {
        DisclosureGroup("Reasoning") {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.vertical, 5)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct ToolRow: View {
    let tool: Synth.ToolCall

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(tool.arguments).textSelection(.enabled)
                if let result = tool.result, !result.isEmpty {
                    Divider()
                    Text(result).textSelection(.enabled)
                }
                if tool.resultBytes > (tool.result?.utf8.count ?? 0) {
                    Text("Output preview").foregroundStyle(.secondary)
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
