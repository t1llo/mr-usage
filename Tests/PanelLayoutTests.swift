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
                Button("Switch provider") { fixture.picking = true }
                    .frame(height: 68)
                    .popover(isPresented: $fixture.picking, arrowEdge: .bottom) {
                        Text("Claude · OpenAI")
                            .padding(20)
                            .onAppear { fixture.popoverVisible = true }
                            .onDisappear { fixture.popoverVisible = false }
                    }
            }
        } content: {
            Color.blue.frame(height: fixture.contentHeight)
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
            menu.setTitle("100% · 100%", provider: "OpenAI")
            try check(menu.layout.maximumHeight)
            fixture.picking = true
            try wait("Provider popover must reopen") { fixture.popoverVisible }
            fixture.picking = false
            fixture.page = "Claude/Limits"
            fixture.contentHeight = 180
            menu.setTitle(index % 2 == 0 ? "1% · 2%" : "Claude", provider: "Claude")
            try check(316)
        }
        print("PASS: repeated tall/short provider switches, nested popovers, exact native size and menu-bar anchoring")

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
