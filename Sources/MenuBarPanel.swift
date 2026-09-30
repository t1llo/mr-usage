import AppKit
import SwiftUI

@MainActor
final class MenuPanelLayout: ObservableObject {
    static let width: CGFloat = 320
    @Published private(set) var maximumHeight: CGFloat = 680
    @Published private(set) var isPresented = false
    private(set) var height: CGFloat = 386
    var onResize: (() -> Void)?
    var onDismiss: (() -> Void)?

    func resize(to height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let height = min(ceil(height), maximumHeight)
        guard height != self.height else { return }
        self.height = height
        onResize?()
    }

    func constrain(to maximum: CGFloat) {
        let maximum = max(1, min(680, floor(maximum)))
        if maximum != maximumHeight { maximumHeight = maximum }
    }

    func setPresented(_ presented: Bool) { if presented != isPresented { isPresented = presented } }
    func dismiss() { onDismiss?() }
}

/// The only owner of the popup's native frame. Always derive its top edge from the actual
/// status button, never from the previous window frame or whichever window has keyboard focus.
@MainActor
final class MenuBarPanelController: NSObject {
    let layout = MenuPanelLayout()
    let statusItem: NSStatusItem
    let panel: NSPanel
    private var observers: [NSObjectProtocol] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init<Content: View>(@ViewBuilder content: (MenuPanelLayout) -> Content) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = UsageMenuWindow(contentRect: NSRect(x: 0, y: 0, width: MenuPanelLayout.width, height: 386),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        // Preserve the position saved by the original single MenuBarExtra, including when a
        // menu-bar organizer is installed. A new, unnamed item can otherwise start hidden.
        statusItem.autosaveName = "Item-0"
        let host = NSHostingView(rootView: content(layout).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        // NSHostingView must not retain a previous page's minimum height or resize the window
        // independently. PanelViewport measures the page; this controller applies the size.
        host.sizingOptions = []
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        (panel as? UsageMenuWindow)?.onCancel = { [weak self] in self?.hide() }
        layout.onResize = { [weak self] in _ = self?.updateFrame() }
        layout.onDismiss = { [weak self] in self?.hide() }
        if let button = statusItem.button {
            button.title = "Mr. Usage"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Mr. Usage")
            button.target = self
            button.action = #selector(toggle)
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow,
                          window === self.statusItem.button?.window, self.panel.isVisible else { return }
                    self.updateFrame()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.panel.isVisible == true { self?.updateFrame() }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.hide() }
            }
        })
    }

    func setTitle(_ title: String, provider: String) {
        guard let button = statusItem.button else { return }
        button.toolTip = "Mr. Usage · \(provider)"
        guard button.title != title else { return }
        button.title = title
        // The status item can move when its text or a neighboring menu item changes width.
        DispatchQueue.main.async { [weak self] in
            if self?.panel.isVisible == true { self?.updateFrame() }
        }
    }

    @objc private func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        guard updateFrame() else { return }
        layout.setPresented(true)
        panel.makeKeyAndOrderFront(nil)
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.hide() }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // Provider/theme popovers and menus are separate windows in this app. They
                // must not dismiss or re-anchor their parent when they take keyboard focus.
                if event.window == nil { self?.hide() }
                return event
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        if layout.isPresented { layout.setPresented(false) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    @discardableResult private func updateFrame() -> Bool {
        guard let button = statusItem.button, let window = button.window, let screen = window.screen else { return false }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Status items briefly have a zero/offscreen frame while AppKit installs them.
        guard !anchor.isEmpty, anchor.intersects(screen.frame), anchor.maxY > screen.visibleFrame.midY else { return false }
        let top = min(anchor.minY, screen.visibleFrame.maxY) - 5
        layout.constrain(to: top - screen.visibleFrame.minY - 8)
        let size = NSSize(width: MenuPanelLayout.width, height: min(layout.height, layout.maximumHeight))
        let x = min(max(anchor.midX - size.width / 2, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - size.width - 6)
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible, animate: false) }
        return true
    }

    deinit {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private final class UsageMenuWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
