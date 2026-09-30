// Quiet, translucent surfaces with accents inspired by Tokyo Night and Catppuccin.
import AppKit
import SwiftUI

struct Theme: Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    let base: Color     // panel background
    let card: Color     // card fill
    let track: Color    // empty part of progress tracks
    let border: Color   // hairlines
    let text: Color
    let subtext: Color
    let muted: Color    // captions
    let accent: Color
    let green: Color
    let warn: Color
    let red: Color
    let blue: Color
    let cyan: Color
    let orange: Color
    let teal: Color

    /// Accent while there is room, warning color from 75%, red from 90%.
    func level(_ pct: Double) -> Color { pct >= 90 ? red : pct >= 75 ? warn : accent }

    static let tokyoNight = Theme(
        id: "tokyo-night", name: "Tokyo Night", isDark: true,
        base: Color(hex: 0x161920), card: .white.opacity(0.045), track: .white.opacity(0.07),
        border: .white.opacity(0.09), text: Color(hex: 0xF0F2F6), subtext: Color(hex: 0xB4BBC9),
        muted: Color(hex: 0x8891A2), accent: Color(hex: 0xA3B7F5),
        green: Color(hex: 0x9ECE6A), warn: Color(hex: 0xE0AF68), red: Color(hex: 0xF7768E),
        blue: Color(hex: 0x7AA2F7), cyan: Color(hex: 0x7DCFFF), orange: Color(hex: 0xFF9E64),
        teal: Color(hex: 0x73DACA))

    static let catppuccinMocha = Theme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
        base: Color(hex: 0x211E29), card: .white.opacity(0.045), track: .white.opacity(0.07),
        border: .white.opacity(0.09), text: Color(hex: 0xEFEAF5), subtext: Color(hex: 0xBBB2C9),
        muted: Color(hex: 0x978CA8), accent: Color(hex: 0xC4B5ED),
        green: Color(hex: 0xA6E3A1), warn: Color(hex: 0xFAB387), red: Color(hex: 0xF38BA8),
        blue: Color(hex: 0x89B4FA), cyan: Color(hex: 0x89DCEB), orange: Color(hex: 0xFAB387),
        teal: Color(hex: 0x94E2D5))

    static let catppuccinLatte = Theme(
        id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
        base: Color(hex: 0xF2F3F5), card: .white.opacity(0.52), track: .black.opacity(0.055),
        border: .black.opacity(0.075), text: Color(hex: 0x292D37), subtext: Color(hex: 0x626B7C),
        muted: Color(hex: 0x7A8497), accent: Color(hex: 0x496EAF),
        green: Color(hex: 0x40A02B), warn: Color(hex: 0xFE640B), red: Color(hex: 0xD20F39),
        blue: Color(hex: 0x1E66F5), cyan: Color(hex: 0x04A5E5), orange: Color(hex: 0xFE640B),
        teal: Color(hex: 0x179299))

    static let all = [tokyoNight, catppuccinMocha, catppuccinLatte]
    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? tokyoNight }
}

/// Real desktop translucency, rather than a transparent color over an opaque hosting window.
private struct PanelMaterial: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

struct PanelBackground: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                t.base
            } else {
                PanelMaterial(isDark: t.isDark)
                t.base.opacity(t.isDark ? 0.56 : 0.42)
            }
            LinearGradient(colors: [.white.opacity(t.isDark ? 0.045 : 0.22), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(t.border, lineWidth: 0.5))
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.tokyoNight }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Explicitly themed controls stay visible in both light and dark menu bar panels.
struct PanelToolbarButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.theme) private var t
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? t.accent : hovered ? t.text : t.muted)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? t.accent.opacity(0.10) : t.text.opacity(hovered || configuration.isPressed ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

struct PanelActionButtonStyle: ButtonStyle {
    @Environment(\.theme) private var t
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(enabled ? t.accent : t.muted)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(enabled ? t.accent.opacity(configuration.isPressed ? 0.18 : 0.10) : t.track.opacity(0.5)))
    }
}

struct ThemePicker: View {
    @Binding var selection: String
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Appearance")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            ForEach(Theme.all) { theme in
                Button {
                    selection = theme.id
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.base)
                            .overlay(Circle().fill(theme.accent).frame(width: 7, height: 7))
                            .frame(width: 28, height: 22)
                        .accessibilityHidden(true)
                        Text(theme.name).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(t.accent)
                            .opacity(selection == theme.id ? 1 : 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == theme.id ? t.text.opacity(0.06) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(selection == theme.id ? "Selected" : "")
            }
        }
    }
}

/// Understated tabs for pages; compact glass segments for chart ranges and data sources.
struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    var fill = false
    var showsSelection = true
    var isTabBar = false
    let label: (T) -> String
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ns

    var body: some View {
        HStack(spacing: isTabBar ? 18 : 2) {
            ForEach(options, id: \.self) { o in
                let selected = showsSelection && o == selection
                Button { selection = o } label: {
                    Text(label(o))
                        .font(.system(size: isTabBar ? 12 : 10, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? t.text : t.muted)
                        .padding(.vertical, isTabBar ? 8 : 5)
                        .padding(.horizontal, isTabBar ? 2 : 9)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .background(alignment: isTabBar ? .bottom : .center) {
                            if selected {
                                RoundedRectangle(cornerRadius: isTabBar ? 1 : 6, style: .continuous)
                                    .fill(isTabBar ? t.accent.opacity(0.85) : t.text.opacity(0.085))
                                    .frame(height: isTabBar ? 2 : nil)
                                    .matchedGeometryEffect(id: "selection", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(isTabBar ? 0 : 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isTabBar ? .clear : t.track.opacity(0.45)))
        .overlay(alignment: .bottom) {
            if isTabBar { Rectangle().fill(t.border.opacity(0.6)).frame(height: 0.5) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
    }
}
