// Color themes. The panel paints its own background, so every color comes from here rather
// than from the system appearance. Palettes follow the official Tokyo Night and Catppuccin specs.
import SwiftUI

struct Theme: Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    let base: Color     // panel background
    let card: Color     // card fill
    let track: Color    // empty part of bars and rings
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
        base: Color(hex: 0x1A1B26), card: Color(hex: 0x24283B), track: Color(hex: 0x292E42),
        border: Color(hex: 0x3B4261), text: Color(hex: 0xC0CAF5), subtext: Color(hex: 0xA9B1D6),
        muted: Color(hex: 0x737AA2), accent: Color(hex: 0x7AA2F7),
        green: Color(hex: 0x9ECE6A), warn: Color(hex: 0xE0AF68), red: Color(hex: 0xF7768E),
        blue: Color(hex: 0x7AA2F7), cyan: Color(hex: 0x7DCFFF), orange: Color(hex: 0xFF9E64),
        teal: Color(hex: 0x73DACA))

    static let catppuccinMocha = Theme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
        base: Color(hex: 0x1E1E2E), card: Color(hex: 0x313244).opacity(0.55), track: Color(hex: 0x313244),
        border: Color(hex: 0x45475A), text: Color(hex: 0xCDD6F4), subtext: Color(hex: 0xBAC2DE),
        muted: Color(hex: 0x7F849C), accent: Color(hex: 0x89B4FA),
        green: Color(hex: 0xA6E3A1), warn: Color(hex: 0xFAB387), red: Color(hex: 0xF38BA8),
        blue: Color(hex: 0x89B4FA), cyan: Color(hex: 0x89DCEB), orange: Color(hex: 0xFAB387),
        teal: Color(hex: 0x94E2D5))

    static let catppuccinLatte = Theme(
        id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
        base: Color(hex: 0xEFF1F5), card: Color(hex: 0xE6E9EF), track: Color(hex: 0xCCD0DA),
        border: Color(hex: 0xBCC0CC), text: Color(hex: 0x4C4F69), subtext: Color(hex: 0x5C5F77),
        muted: Color(hex: 0x8C8FA1), accent: Color(hex: 0x1E66F5),
        green: Color(hex: 0x40A02B), warn: Color(hex: 0xFE640B), red: Color(hex: 0xD20F39),
        blue: Color(hex: 0x1E66F5), cyan: Color(hex: 0x04A5E5), orange: Color(hex: 0xFE640B),
        teal: Color(hex: 0x179299))

    static let all = [tokyoNight, catppuccinMocha, catppuccinLatte]
    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? tokyoNight }
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

/// Pill-shaped segmented control in theme colors; the selection slides between options.
struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    var fill = false
    let label: (T) -> String
    @Environment(\.theme) private var t
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Text(label(o))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(o == selection ? t.base : t.subtext)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .background {
                        if o == selection {
                            Capsule().fill(t.accent).matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = o } }
            }
        }
        .padding(2)
        .background(Capsule().fill(t.track.opacity(0.7)))
        .overlay(Capsule().strokeBorder(t.border.opacity(0.6), lineWidth: 0.5))
    }
}
