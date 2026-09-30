// Mr. Usage: a tiny macOS menu bar app that shows the same numbers as `/usage` in Claude Code,
// and the ChatGPT plan limits Codex CLI logs. Data sources: the usage endpoint Claude Code itself
// calls, authenticated with the OAuth token `claude login` stored in the macOS Keychain, plus the
// local logs of Claude Code, Codex and OpenCode. Nothing to configure.
import AppKit
import Combine
import SwiftUI

struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(MrUsageAppDelegate.self) private var appDelegate

    init() {
        // Refuse to run twice: a second instance would double the request rate.
        let me = Bundle.main.bundleIdentifier ?? "local.tillobeffa.ClaudeUsageBar"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 { exit(0) }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class MrUsageAppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuBarPanelController?
    private var subscriptions: Set<AnyCancellable> = []

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
            menu?.setTitle(provider == .claude ? store.menuTitle : tokens.menuTitle(), provider: provider.rawValue)
        }
        Publishers.Merge(store.objectWillChange, tokens.objectWillChange)
            .receive(on: DispatchQueue.main).sink(receiveValue: updateTitle).store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { _ in updateTitle() }.store(in: &subscriptions)
        updateTitle()
        UpdateService.shared.start()
    }
}

ClaudeUsageBarApp.main()
