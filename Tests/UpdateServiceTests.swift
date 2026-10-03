// Exercise updater callbacks and the native popup-to-window handoff, without a feed request,
// provider credentials, downloads, installation, or starting Sparkle's automatic scheduler.
import AppKit
import Sparkle
import SwiftUI

@main
struct UpdateServiceTests {
    @MainActor static func main() {
        MenuBarApplication.run(delegate: UpdateTestDelegate())
    }

    @MainActor static func runChecks() async throws {
        setbuf(stdout, nil)
        let service = UpdateService()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let delegate: SPUUpdaterDelegate = service
        // The public dictionary initializer is sufficient for synthetic version labels; no
        // system-version or compatibility properties from this deprecated API are exercised.
        let item = SUAppcastItem(dictionary: ["enclosure": [
            "url": "https://example.invalid/update.zip", "sparkle:version": "2",
            "sparkle:shortVersionString": "2.0"
        ]])!
        assert(service.checkTitle == "Check for Updates…")
        delegate.updater?(updater, didFindValidUpdate: item)
        assert(service.availableVersion == "2.0" && service.checkTitle == "Show Update…")
        assert(service.supportsGentleScheduledUpdateReminders)
        assert(!service.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: false))
        assert(service.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true))
        service.standardUserDriverWillFinishUpdateSession()
        assert(service.availableVersion == nil)
        var installed = false
        let ownsInstallation = delegate.updater?(updater, willInstallUpdateOnQuit: item,
                                                 immediateInstallationBlock: { installed = true })
        assert(ownsInstallation == false && !installed, "Sparkle must continue to own installation")
        assert(service.readyToInstall && service.checkTitle == "Install Update…")
        assert(service.status?.contains("quit the app") == true)
        service.standardUserDriverWillFinishUpdateSession()
        assert(service.readyToInstall && service.availableVersion == "2.0", "A staged update keeps its reminder")
        print("PASS: scheduled reminders, ready-to-install state and Sparkle-owned installation")

        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                               userInfo: [NSLocalizedDescriptionKey: "Already up to date."])
        delegate.updaterDidNotFindUpdate?(updater, error: noUpdate)
        delegate.updater?(updater, didAbortWithError: noUpdate)
        assert(service.status == "Already up to date." && !service.readyToInstall)
        let error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
        delegate.updater?(updater, didAbortWithError: error)
        assert(service.status == "Update failed: Network unavailable" && service.availableVersion == nil,
               "Actual Objective-C delegate routing must deliver failures to the visible status")
        service.standardUserDriverWillFinishUpdateSession()
        assert(service.status == "Update failed: Network unavailable")
        service.start()
        assert(!service.started && service.status == "Updates require the packaged app.")
        print("PASS: Objective-C delegate routing, up-to-date/error results and unpackaged startup feedback")

        UserDefaults.standard.setVolatileDomain(["NSStatusItem Preferred Position Item-0": 0], forName: UserDefaults.argumentDomain)
        let menu = MenuBarPanelController { _ in Text("Synthetic usage").frame(width: 320, height: 180) }
        defer { menu.hide() }
        try await wait { menu.statusItem.button?.window?.screen != nil }
        menu.show()
        try await wait { menu.panel.isVisible }
        service.dismissPanel = { menu.hide() }
        let updateWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 160),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        updateWindow.isReleasedWhenClosed = false
        defer { updateWindow.orderOut(nil) }
        var presented = false
        service.presentUpdateUI {
            assert(!menu.panel.isVisible && !menu.layout.isPresented)
            updateWindow.makeKeyAndOrderFront(nil)
            presented = true
        }
        assert(!menu.panel.isVisible && !presented, "Dismiss synchronously, then unwind menu tracking before presenting")
        try await wait { presented && NSApp.isActive && updateWindow.isVisible && updateWindow.isKeyWindow }
        menu.show()
        service.standardUserDriverWillShowModalAlert()
        assert(!menu.panel.isVisible && !menu.layout.isPresented, "No-update and error alerts must not sit under the popup")
        assert(NSApp.activationPolicy() == .accessory, "Update UI must not permanently add a Dock icon")
        print("PASS: native popup dismissal, deferred manual UI, window focus and modal-alert handoff")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 20_000_000)
            if condition() { return }
        } while Date() < deadline
        throw NSError(domain: "UpdateServiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native UI test timed out"])
    }
}

@MainActor
private final class UpdateTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await UpdateServiceTests.runChecks()
                NSApp.terminate(nil)
            } catch {
                print("FAIL:", error)
                exit(1)
            }
        }
    }
}
