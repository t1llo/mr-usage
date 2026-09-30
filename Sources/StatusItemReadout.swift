import AppKit

/// A native template image keeps the menu-bar readout legible on every wallpaper and while
/// selected. Window labels identify the percentages; the little tracks show usage at a glance.
enum StatusItemReadout {
    static func image(provider: String, limits: [Limit]) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let windows = Array(limits.prefix(2))
        let labels = windows.map { shortWindow($0) }
        let values = windows.map { percentage($0.pct) }
        let widths = zip(labels, values).map { label, value in
            width(label, font: labelFont) + 4 + width(value, font: valueFont)
        }
        let fallbackWidth = width(provider, font: valueFont)
        let total = ceil(24 + (windows.isEmpty ? fallbackWidth : widths.reduce(0, +) + CGFloat(max(0, windows.count - 1)) * 10))
        let turtle = NSImage(systemSymbolName: "tortoise.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.black]))
        let image = NSImage(size: NSSize(width: total, height: 22), flipped: false) { _ in
            turtle?.draw(in: NSRect(x: 0, y: 4, width: 18, height: 14))
            if windows.isEmpty {
                draw(provider, at: NSPoint(x: 24, y: 4), font: valueFont)
            } else {
                var x: CGFloat = 24
                for index in windows.indices {
                    draw(labels[index], at: NSPoint(x: x, y: 7), font: labelFont, opacity: 0.7)
                    draw(values[index], at: NSPoint(x: x + width(labels[index], font: labelFont) + 4, y: 5), font: valueFont)
                    let track = NSRect(x: x, y: 2, width: widths[index], height: 2)
                    NSColor.black.withAlphaComponent(0.18).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                    let fraction = windows[index].pct.isFinite ? min(1, max(0, windows[index].pct / 100)) : 0
                    if fraction > 0 {
                        NSColor.black.withAlphaComponent(0.85).setFill()
                        NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: max(2, widths[index] * fraction), height: 2),
                                     xRadius: 1, yRadius: 1).fill()
                    }
                    x += widths[index] + 10
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func description(provider: String, limits: [Limit]) -> String {
        (["Mr. Usage · \(provider)"] + limits.prefix(2).map { "\($0.label): \(percentage($0.pct)) used" }).joined(separator: "\n")
    }

    static func shortWindow(_ limit: Limit) -> String {
        guard let seconds = limit.window, seconds.isFinite, seconds > 0 else { return String(limit.label.prefix(1)) }
        let divisor: Double = seconds >= 86400 ? 86400 : seconds >= 3600 ? 3600 : 60
        let unit = seconds >= 86400 ? "d" : seconds >= 3600 ? "h" : "m"
        let value = seconds / divisor
        return (value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)) + unit
    }

    private static func percentage(_ value: Double) -> String { value.isFinite ? "\(Int(value))%" : "—" }
    private static func width(_ text: String, font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    private static func draw(_ text: String, at point: NSPoint, font: NSFont, opacity: Double = 1) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(opacity)])
    }
}
