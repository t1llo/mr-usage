// ClaudeUsageBar: a tiny macOS menu bar app that shows the same numbers as `/usage` in Claude Code,
// and the ChatGPT plan limits Codex CLI logs. Data sources: the usage endpoint Claude Code itself
// calls, authenticated with the OAuth token `claude login` stored in the macOS Keychain, plus the
// local logs of Claude Code, Codex and OpenCode. Nothing to configure.
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
            MenuTitle(store: store, tokens: tokens)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reads the provider itself, so switching it redraws only this label, not the whole scene.
struct MenuTitle: View {
    @ObservedObject var store: Store
    @ObservedObject var tokens: TokenStore
    @AppStorage("provider") private var provider: Provider = .claude

    var body: some View {
        Text(provider == .claude ? store.menuTitle : tokens.menuTitle()).monospacedDigit()
    }
}

ClaudeUsageBarApp.main()
