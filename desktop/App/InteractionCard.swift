import SwiftUI
import SynthProtocol

struct InteractionCard: View {
    let interaction: Interaction
    let model: ConversationModel
    @State private var answer = ""
    @State private var customAnswer = ""
    @State private var responding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch interaction {
            case .permission(_, let permission):
                permissionBody(permission)
            case .question(_, let question):
                questionBody(question)
            }
        }
        .disabled(responding)
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SynthPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SynthPalette.border))
    }

    private func permissionBody(_ permission: Interaction.Permission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permission required", systemImage: "hand.raised")
                .font(.headline)
                .foregroundStyle(SynthPalette.accent)
            Text(permission.toolCall.title ?? permission.toolCall.toolCallId).textSelection(.enabled)
            if let input = permission.toolCall.rawInput,
               let data = try? prettyEncoder.encode(input),
               let arguments = String(bytes: data, encoding: .utf8) {
                Text(arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack { permissionButtons(permission.options) }
                VStack(alignment: .leading) { permissionButtons(permission.options) }
            }
        }
    }

    private func permissionButtons(_ options: [Interaction.Permission.Option]) -> some View {
        ForEach(options) { option in
            Button(option.name) {
                respond { await model.decide(interaction.id, option: option.optionId) }
            }
            .tint(option.kind.hasPrefix("reject_") ? SynthPalette.danger : SynthPalette.accent)
        }
    }

    private func questionBody(_ question: Interaction.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(question.message, systemImage: "questionmark.bubble").font(.headline)
            let field = question.requestedSchema.properties["answer"]
            if let choices = field?.oneOf, !choices.isEmpty {
                Picker(field?.title ?? "Answer", selection: $answer) {
                    Text("Choose an answer").tag("")
                    ForEach(choices, id: \.const) { choice in
                        Text(choice.title).tag(choice.const)
                    }
                }
                if let other = question.requestedSchema.properties["other"] {
                    TextField(other.title ?? "Your own answer", text: $customAnswer)
                }
            } else {
                TextField(field?.title ?? "Answer", text: $answer)
            }
            HStack {
                Button("Reply") {
                    respond {
                        var fields = [String: String]()
                        if !answer.isEmpty { fields["answer"] = answer }
                        if !customAnswer.isEmpty { fields["other"] = customAnswer }
                        await model.answer(interaction.id, fields: fields)
                    }
                }
                .disabled(answer.isEmpty && customAnswer.isEmpty)
                Button("Decline") { respond { await model.decline(interaction.id) } }
            }
        }
    }

    private func respond(_ action: @escaping @MainActor () async -> Void) {
        guard !responding else { return }
        responding = true
        Task {
            await action()
            responding = false
        }
    }

    private var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
