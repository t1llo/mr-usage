// ClaudeUsageBar: a tiny macOS menu bar app that shows the same numbers as `/usage` in Claude Code.
// Data source: the usage endpoint Claude Code itself calls, authenticated with the OAuth token
// that `claude login` stored in the macOS Keychain. Nothing to configure.
import AppKit
import SwiftUI

struct ClaudeUsageBarApp: App {
    @StateObject private var store = Store()
    @StateObject private var tokens = TokenStore()

    init() {
        // Refuse to run twice: a second instance would double the request rate.
        let me = Bundle.main.bundleIdentifier ?? "local.tillobeffa.ClaudeUsageBar"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store, tokens: tokens)
        } label: {
            Text(store.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

ClaudeUsageBarApp.main()
