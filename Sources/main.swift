// Mr. Usage: a tiny macOS menu bar app that shows the same numbers as `/usage` in Claude Code,
// and the ChatGPT plan limits Codex CLI logs. Data sources: the usage endpoint Claude Code itself
// calls, authenticated with the OAuth token `claude login` stored in the macOS Keychain, plus the
// local logs of Claude Code, Codex and OpenCode. Nothing to configure.
import AppKit
import Combine

enum ClaudeUsageBarApp {
    @MainActor static func main() {
        // Refuse to run twice: a second instance would double the request rate.
        let me = Bundle.main.bundleIdentifier ?? "local.tillobeffa.ClaudeUsageBar"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 { exit(0) }
        MenuBarApplication.run(delegate: MrUsageAppDelegate())
    }
}

@MainActor
final class MrUsageAppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuBarPanelController?
    private var subscriptions: Set<AnyCancellable> = []
    private var appearanceObserver: NSKeyValueObservation?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Store()
        let tokens = TokenStore()
        let leaderboard = LeaderboardStore(tokens: tokens)
        let menu = MenuBarPanelController { layout in
            UsagePanel(store: store, tokens: tokens, leaderboard: leaderboard, layout: layout)
        }
        self.menu = menu
        let updateTitle = { [weak menu] in
            let provider = UserDefaults.standard.string(forKey: "provider").flatMap(Provider.init(rawValue:)) ?? .claude
            let limits = provider == .claude ? store.usage?.limits : tokens.codexLimits?.current(now: Date()).limits
            menu?.setUsage(provider: provider.rawValue, limits: limits ?? [])
        }
        Publishers.Merge(store.objectWillChange, tokens.objectWillChange)
            .receive(on: DispatchQueue.main).sink(receiveValue: updateTitle).store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { _ in updateTitle() }.store(in: &subscriptions)
        updateTitle()
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            Task { @MainActor in
                NSApp.applicationIconImage = AppBranding.icon(isDark: app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            }
        }
        UpdateService.shared.start()
    }
}

MainActor.assumeIsolated { ClaudeUsageBarApp.main() }
