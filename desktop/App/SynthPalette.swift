import SwiftUI

enum SynthPalette {
    static let background = color(0x1C1E25)
    static let surface = color(0x22242C)
    static let alternateSurface = color(0x3A332E)
    static let foreground = color(0xE7E5DD)
    static let muted = color(0x8B8E99)
    static let accent = color(0xE8A33D)
    static let success = color(0x5FC9A8)
    static let danger = color(0xE2695B)
    static let border = color(0x34363F)

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

struct SynthProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isEnabled ? SynthPalette.background : SynthPalette.muted)
            .modifier(SynthButtonBackground(
                idle: isEnabled ? SynthPalette.accent : SynthPalette.border,
                hovered: SynthPalette.accent.opacity(0.9),
                pressed: SynthPalette.accent.opacity(0.78),
                isPressed: configuration.isPressed
            ))
    }
}

struct SynthButtonBackground: ViewModifier {
    let idle: Color
    let hovered: Color
    let pressed: Color
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var fill: Color {
        guard isEnabled else { return idle }
        if isPressed { return pressed }
        return isHovered ? hovered : idle
    }

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isHovered = inside
                }
            }
    }
}
