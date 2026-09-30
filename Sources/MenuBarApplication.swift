import AppKit

/// The app owns a status item and transient panels, not any SwiftUI window scenes.
@MainActor
final class MenuBarApplication: NSApplication {
    // NSApplication.delegate is weak; the app must own its controller and stores.
    private var retainedDelegate: NSApplicationDelegate?

    static func run(delegate: NSApplicationDelegate) {
        let app = MenuBarApplication.shared as! MenuBarApplication
        app.setActivationPolicy(.accessory)
        app.retainedDelegate = delegate
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        app.run()
    }

    private static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: "Quit Mr. Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(application)

        // SwiftUI.App used to supply the standard editing commands. Keep them in the
        // responder chain so profile fields still support undo, copy/paste and select-all.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"),
                                     ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        return menu
    }

    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                                completionHandler: @escaping (NSWindow?, Error?) -> Void) -> Bool {
        // Older builds registered Settings { EmptyView() }. Discard any saved window
        // from that scene rather than bringing its blank Settings window back on login.
        completionHandler(nil, nil)
        return true
    }
}
