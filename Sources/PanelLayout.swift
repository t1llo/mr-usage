import AppKit
import SwiftUI

struct PanelHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func measurePanelHeight(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeights.self, value: [key: geometry.size.height])
        })
    }
}

/// MenuBarExtra can center its window when its intrinsic size changes. Keep the top/trailing
/// corner from the current presentation, so a shorter Limits page shrinks upwards from below.
struct PanelWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var previous: NSRect?
        private var pending: NSPoint?
        private var adjusting = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            previous = nil
            pending = nil
            guard let window else { return }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.frameChanged()
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.previous = nil
                self?.pending = nil
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.rememberFrame() }
            })
            // Let AppKit first place a newly opened menu on the appropriate screen.
            DispatchQueue.main.async { [weak self] in self?.rememberFrame() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func rememberFrame() {
            previous = window.flatMap { $0.isVisible ? $0.frame : nil }
        }

        private func frameChanged() {
            guard !adjusting, let window, window.isVisible else { return }
            guard let previous else { rememberFrame(); return }
            if previous.size != window.frame.size, pending == nil {
                pending = NSPoint(x: previous.maxX, y: previous.maxY)
                DispatchQueue.main.async { [weak self] in self?.restoreAnchor() }
            } else if pending == nil {
                rememberFrame()
            }
        }

        private func restoreAnchor() {
            guard let anchor = pending, let window, window.isVisible else { pending = nil; return }
            var origin = NSPoint(x: anchor.x - window.frame.width, y: anchor.y - window.frame.height)
            if let screen = window.screen?.visibleFrame {
                origin.x = max(screen.minX, min(origin.x, screen.maxX - window.frame.width))
                origin.y = max(screen.minY, min(origin.y, screen.maxY - window.frame.height))
            }
            adjusting = true
            window.setFrameOrigin(origin)
            adjusting = false
            pending = nil
            rememberFrame()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
