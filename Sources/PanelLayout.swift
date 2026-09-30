import SwiftUI

private struct PanelHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    func measurePanelHeight(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeights.self, value: [key: geometry.size.height])
        })
    }
}

/// Measures unconstrained page content, then reports one exact size to the native panel.
/// Header and footer stay fixed; long pages scroll inside the screen-capped viewport.
struct PanelViewport<Header: View, Content: View, Footer: View>: View {
    @ObservedObject var layout: MenuPanelLayout
    let page: String
    let fitsContent: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @State private var heights: [String: CGFloat] = [:]

    private var height: CGFloat {
        guard fitsContent else { return layout.maximumHeight }
        // Two 12-point gaps and 14-point outer padding. Chrome is measured, not guessed.
        let natural = (heights["header"] ?? 68) + (heights[page] ?? 250) + (heights["footer"] ?? 16) + 52
        return min(layout.maximumHeight, ceil(natural))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.fixedSize(horizontal: false, vertical: true).measurePanelHeight("header")
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .measurePanelHeight(page)
            }
            .id(page)
            footer.fixedSize(horizontal: false, vertical: true).measurePanelHeight("footer")
        }
        .padding(14)
        .frame(width: MenuPanelLayout.width, height: height, alignment: .top)
        .onPreferenceChange(PanelHeights.self) { values in
            let measured = values.filter { $0.value >= 0 && $0.value.isFinite }
            if measured.contains(where: { heights[$0.key] != $0.value }) {
                heights.merge(measured) { _, new in new }
            }
        }
        .onAppear { layout.resize(to: height) }
        .onChange(of: height) { layout.resize(to: $0) }
    }
}
