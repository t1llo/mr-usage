import AppKit
import SwiftUI

/// The same artwork is bundled with the app and published in the website and README.
enum AppBranding {
    private static let light = load("app-icon-light")
    private static let dark = load("app-icon-dark")

    static func icon(isDark: Bool) -> NSImage {
        (isDark ? dark : light) ?? NSImage(systemSymbolName: "tortoise.fill", accessibilityDescription: "Mr. Usage")!
    }

    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}

struct AppIcon: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Image(nsImage: AppBranding.icon(isDark: theme.isDark))
            .resizable().interpolation(.high).scaledToFit()
            .accessibilityHidden(true)
    }
}
