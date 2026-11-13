import SwiftUI

struct ConversationPopoverLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .foregroundStyle(SynthPalette.foreground)
    }
}

struct ConversationPopover<Content: View>: View {
    var width: CGFloat = 220
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(SynthPalette.surface)
        .foregroundStyle(SynthPalette.foreground)
    }
}

struct ConversationPopoverRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .foregroundStyle(color(for: configuration.role))
            .modifier(SynthButtonBackground(
                idle: .clear,
                hovered: SynthPalette.alternateSurface.opacity(0.65),
                pressed: SynthPalette.alternateSurface,
                isPressed: configuration.isPressed
            ))
    }

    private func color(for role: ButtonRole?) -> Color {
        guard isEnabled else { return SynthPalette.muted }
        return role == .destructive ? SynthPalette.danger : SynthPalette.foreground
    }
}
