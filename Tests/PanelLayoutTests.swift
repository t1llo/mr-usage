// Exercise the real status item, native panel, SwiftUI viewport and nested provider popover.
// Synthetic content only: no stores, provider credentials, local logs or network requests.
import AppKit
import SwiftUI

@MainActor
private final class Fixture: ObservableObject {
    @Published var page = "Claude/Limits"
    @Published var contentHeight: CGFloat = 180
    @Published var fitsContent = true
    @Published var picking = false
    @Published var name = ""
    var popoverVisible = false
    var renderedSize = CGSize.zero
    var detailsVisible = false
}

private struct RenderedSize: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct FixtureView: View {
    @ObservedObject var fixture: Fixture
    @ObservedObject var layout: MenuPanelLayout
    @FocusState private var editing: Bool

    var body: some View {
        PanelViewport(layout: layout, page: fixture.page, fitsContent: fixture.fitsContent) {
            if fixture.page == "settings" {
                TextField("Display name", text: $fixture.name)
                    .focused($editing).frame(height: 68)
                    .onAppear { editing = true }
            } else {
                VStack(spacing: 12) {
                    Button("Switch provider") { fixture.picking = true }
                        .frame(height: 28)
                        .popover(isPresented: $fixture.picking, arrowEdge: .bottom) {
                            Text("Claude · OpenAI")
                                .padding(20)
                                .onAppear { fixture.popoverVisible = true }
                                .onDisappear { fixture.popoverVisible = false }
                        }
                    Segmented(options: ["Limits", "Tokens"], selection: Binding(
                        get: { fixture.fitsContent ? "Limits" : "Tokens" },
                        set: {
                            fixture.page = "Claude/\($0)"
                            fixture.fitsContent = $0 == "Limits"
                            fixture.contentHeight = fixture.fitsContent ? 180 : 1100
                        }), fill: true, isTabBar: true) { $0 }
                        .frame(height: 28)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if fixture.page == "settings" {
                    PanelDisclosure(title: "Exactly what gets shared") {
                        Text("Uploaded fields: synthetic daily token counts")
                            .frame(height: 80)
                            .onAppear { fixture.detailsVisible = true }
                            .onDisappear { fixture.detailsVisible = false }
                    }
                }
                Color.blue.frame(height: fixture.contentHeight)
            }
        } footer: {
            Text("Footer").frame(height: 16)
        }
        .background(Color.gray)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: RenderedSize.self, value: geometry.size)
        })
        .onPreferenceChange(RenderedSize.self) { fixture.renderedSize = $0 }
        .onExitCommand { layout.dismiss() }
    }
}

@main
struct PanelLayoutTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        // Keep this isolated test process's item on the visible side of menu-bar organizers.
        UserDefaults.standard.setVolatileDomain(["NSStatusItem Preferred Position Item-0": 0], forName: UserDefaults.argumentDomain)
        app.activate(ignoringOtherApps: true)
        let fixture = Fixture()
        let menu = MenuBarPanelController { FixtureView(fixture: fixture, layout: $0) }
        defer { menu.hide() }
        try wait("Status item must be placed in the menu bar") {
            guard let window = menu.statusItem.button?.window, let screen = window.screen else { return false }
            return window.frame.intersects(screen.frame) && window.frame.maxY > screen.visibleFrame.midY
        }
        menu.show()

        func check(_ expectedHeight: CGFloat) throws {
            do {
                try wait("Window and rendered content must both shrink/grow to \(expectedHeight) points") {
                    guard let button = menu.statusItem.button, let window = button.window, let screen = window.screen else { return false }
                    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
                    return menu.panel.isVisible && abs(menu.panel.frame.height - expectedHeight) < 1
                        && abs(fixture.renderedSize.height - expectedHeight) < 1
                        && abs(menu.panel.frame.maxY - (min(anchor.minY, screen.visibleFrame.maxY) - 5)) < 1
                }
            } catch {
                print("Layout failure:", fixture.page, "window:", menu.panel.frame, "rendered:", fixture.renderedSize,
                      "requested:", menu.layout.height, "cap:", menu.layout.maximumHeight,
                      "visible:", menu.panel.isVisible, "status item:", menu.statusItem.button?.window?.frame as Any)
                throw error
            }
            let button = menu.statusItem.button!
            let window = button.window!
            let screen = window.screen!.visibleFrame
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let frame = menu.panel.frame
            assert(menu.panel.isVisible && menu.layout.isPresented)
            assert(abs(frame.maxY - (min(anchor.minY, screen.maxY) - 5)) < 1,
                   "Every resize must stay directly below the menu bar, including after a popover takes focus")
            assert(frame.minX >= screen.minX && frame.maxX <= screen.maxX && frame.minY >= screen.minY)
            assert(frame.width == 320 && fixture.renderedSize.width == 320)
            assert(menu.panel.contentView!.bounds.size == frame.size,
                   "The native popup must not keep an empty area outside the SwiftUI page")
        }
        try check(316)

        // This reproduces the original sequence, including the separate window/focus change
        // caused by the provider picker. Repeat to catch stale heights and accumulated drift.
        for index in 0..<5 {
            fixture.picking = true
            try wait("Provider popover must open") { fixture.popoverVisible }
            fixture.picking = false
            fixture.page = "OpenAI/Limits"
            fixture.contentHeight = 900
            menu.setUsage(provider: "OpenAI", limits: [
                Limit(id: "session", label: "Session", pct: 100, resetsAt: nil, window: 18000),
                Limit(id: "week", label: "Weekly", pct: 100, resetsAt: nil, window: 604800)])
            try check(menu.layout.maximumHeight)
            fixture.picking = true
            try wait("Provider popover must reopen") { fixture.popoverVisible }
            fixture.picking = false
            fixture.page = "Claude/Limits"
            fixture.contentHeight = 180
            menu.setUsage(provider: "Claude", limits: index % 2 == 0 ? [
                Limit(id: "session", label: "Session", pct: 1, resetsAt: nil, window: 18000),
                Limit(id: "week", label: "Weekly", pct: 2, resetsAt: nil, window: 604800)] : [])
            try check(316)
        }
        print("PASS: repeated tall/short provider switches, nested popovers, exact native size and menu-bar anchoring")

        for _ in 0..<6 {
            click(NSPoint(x: 240, y: menu.panel.frame.height - 68), in: menu.panel)
            try wait("Clicking Tokens must select the page") { fixture.page == "Claude/Tokens" }
            try check(menu.layout.maximumHeight)
            click(NSPoint(x: 75, y: menu.panel.frame.height - 68), in: menu.panel)
            try wait("Clicking Limits must select the page") { fixture.page == "Claude/Limits" }
            try check(316)
        }
        let custom = Limit(id: "custom", label: "Custom session", pct: 34, resetsAt: nil, window: 10800)
        assert(StatusItemReadout.shortWindow(custom) == "3h", "Use server-defined windows in the menu bar")
        menu.setUsage(provider: "OpenAI", limits: [custom])
        assert(menu.statusItem.button!.image!.isTemplate)
        assert(menu.statusItem.button!.toolTip!.contains("Custom session: 34% used"))
        print("PASS: real Limits/Tokens buttons, repeated page resizing and labeled template menu-bar readouts")

        fixture.page = "Claude/Tokens"
        fixture.fitsContent = false
        fixture.contentHeight = 1100
        try check(menu.layout.maximumHeight)
        fixture.page = "settings"
        fixture.contentHeight = 1400
        try check(menu.layout.maximumHeight)
        try wait("Settings text field must receive keyboard focus") { menu.panel.firstResponder is NSTextView }
        sendKey("a", code: 0, to: menu.panel)
        try wait("Typing in the nonactivating panel must edit the profile field") { fixture.name == "a" }
        // Click the text well away from the chevron: the entire sharing-details row is active.
        click(NSPoint(x: 170, y: menu.panel.frame.height - 108), in: menu.panel)
        try wait("Clicking sharing-details text must expand it") { fixture.detailsVisible }
        try check(menu.layout.maximumHeight)
        click(NSPoint(x: 170, y: menu.panel.frame.height - 108), in: menu.panel)
        try wait("Clicking sharing-details text again must collapse it") { !fixture.detailsVisible }
        print("PASS: sharing disclosure expands and collapses by clicking its label")
        fixture.page = "Claude/Limits"
        fixture.fitsContent = true
        fixture.contentHeight = 180
        try check(316)
        fixture.contentHeight = 100 // A refresh can shorten the current page without changing its identity.
        try check(236)
        fixture.contentHeight = 0
        try check(136)
        print("PASS: Tokens/Settings retain their viewport; Limits and refreshed empty content shrink correctly")

        fixture.page = "OpenAI/Limits"
        fixture.contentHeight = 900
        try check(menu.layout.maximumHeight)
        menu.hide()
        assert(!menu.panel.isVisible && !menu.layout.isPresented)
        fixture.page = "Claude/Limits"
        fixture.contentHeight = 180
        menu.show()
        try check(316)
        sendKey("\u{1b}", code: 53, to: menu.panel)
        try wait("Escape must dismiss the popup") { !menu.panel.isVisible && !menu.layout.isPresented }
        menu.statusItem.button!.performClick(nil)
        try check(316)
        menu.statusItem.button!.performClick(nil)
        assert(!menu.panel.isVisible)
        print("PASS: Settings keyboard input, close/reopen, Escape and status-button toggling")
    }

    @MainActor private static func sendKey(_ characters: String, code: UInt16, to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }

    @MainActor private static func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    @MainActor private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            // Pump actual AppKit events as well as SwiftUI's run-loop layout work.
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            if condition() { return }
        } while Date() < deadline
        throw NSError(domain: "PanelLayoutTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
