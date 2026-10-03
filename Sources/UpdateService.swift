import AppKit
import Combine
import OSLog
import Sparkle
import SwiftUI

@MainActor
// Sparkle calls its UI delegate on the main thread, but 2.10 does not annotate that protocol.
final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = UpdateService()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    @Published private(set) var started = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var readyToInstall = false
    @Published private(set) var status: String?
    /// The native popup floats above ordinary windows. Dismiss it before Sparkle presents UI.
    var dismissPanel: (() -> Void)?
    private let logger = Logger(subsystem: "local.tillobeffa.ClaudeUsageBar", category: "Updates")
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    override init() {
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticDownloads)
    }

    func start() {
        guard !started else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            status = "Updates require the packaged app."
            return
        }
        do {
            // Capture startup failures instead of only logging an error behind the popup.
            try controller.updater.start()
            started = true
        } catch {
            status = "Updater could not start: \(error.localizedDescription)"
            logger.error("Updater startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func check() {
        guard started, canCheck else { return }
        presentUpdateUI { [weak self] in
            guard let self, self.controller.updater.canCheckForUpdates else { return }
            if self.availableVersion == nil { self.status = "Checking for updates…" }
            self.logger.info("User requested an update check")
            // Also brings an already-downloaded update or existing Sparkle window into focus.
            self.controller.checkForUpdates(nil)
        }
    }

    func presentUpdateUI(_ action: @escaping () -> Void) {
        dismissPanel?()
        // Let the SwiftUI menu finish tracking before opening a normal AppKit window.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
    }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    var checkTitle: String {
        readyToInstall ? "Install Update…" : availableVersion != nil ? "Show Update…" : "Check for Updates…"
    }

    // Background apps otherwise leave scheduled update alerts behind other applications.
    // Keep a visible reminder in our own menu without stealing focus or adding a Dock icon.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        status = "Version \(update.displayVersionString) is available."
        if handleShowingUpdate { dismissPanel?() }
    }

    func standardUserDriverWillShowModalAlert() {
        dismissPanel?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        if !readyToInstall, availableVersion != nil {
            availableVersion = nil
            status = "Update dismissed. Check again to show it."
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = "Version \(item.displayVersionString) is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
        readyToInstall = false
        status = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        readyToInstall = true
        status = "Version \(item.displayVersionString) is ready to install. Install now, or quit the app."
        return false // Sparkle continues scheduling and owns installation/relaunch.
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain != SUSparkleErrorDomain || nsError.code != SUError.noUpdateError.rawValue else { return }
        readyToInstall = false
        availableVersion = nil
        status = "Update failed: \(error.localizedDescription)"
        logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
    }
}

struct SoftwareUpdateMenu: View {
    @ObservedObject private var updater = UpdateService.shared
    var body: some View {
        Menu {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
            if let status = updater.status { Text(status).help(status) }
            else if updater.started && !updater.canCheck { Text("Update in progress…") }
            Button(updater.checkTitle) { updater.check() }.disabled(!updater.canCheck)
            Link("Download latest release…", destination: URL(string: "https://github.com/t1llo/mr-usage/releases/latest")!)
            Divider()
            Toggle("Check automatically", isOn: Binding(
                get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
            .disabled(!updater.started)
            Toggle("Download and install automatically", isOn: Binding(
                get: { updater.automaticDownloads }, set: updater.setAutomaticDownloads))
            .disabled(!updater.started)
        } label: {
            Image(systemName: "arrow.down.to.line")
                .overlay(alignment: .topTrailing) {
                    if updater.availableVersion != nil {
                        Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 3, y: -2)
                    }
                }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(updater.status ?? "Software updates").accessibilityLabel("Software updates")
        .accessibilityValue(updater.status ?? "")
    }
}
