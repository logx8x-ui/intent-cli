import SwiftUI
import IntentCore

struct AppStackOverview<Card: View>: View {
    let items: [AppStackLayout.Item]
    let area: CGRect
    let obstacle: CGRect?
    let selected: Set<UInt32>
    let names: [String: String]
    @Binding var fronts: [String: UInt32]
    @Binding var expanded: String?
    let hovered: UInt32?
    let card: (UInt32, CGRect, CGRect, Bool) -> Card
    @State private var groups: [AppStackLayout.Group] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Input: Hashable {
        var items: [AppStackLayout.Item]; var area: CGRect; var obstacle: CGRect?
        func hash(into hasher: inout Hasher) {
            func rect(_ rect: CGRect) {
                hasher.combine(rect.origin.x); hasher.combine(rect.origin.y)
                hasher.combine(rect.width); hasher.combine(rect.height)
            }
            rect(area); if let obstacle { rect(obstacle) }
            for item in items { hasher.combine(item.id); hasher.combine(item.app); hasher.combine(item.tabCount); rect(item.source) }
        }
    }
    var body: some View {
        let input = Input(items: items, area: area, obstacle: obstacle)
        ZStack(alignment: .topLeading) {
            ForEach(groups, id: \.app) { group in
                ZStack(alignment: .topLeading) {
                    ForEach(group.windows, id: \.id) { window in
                        card(window.id, window.frame, window.captionFrame, true)
                            .zIndex(layer(for: window.id, in: group))
                    }
                }
                .zIndex(group.ids.contains(hovered ?? 0) ? 1 : 0)
            }
        }
        .task(id: input) { await updateLayout(input) }
        .onAppear { expanded = nil }
    }
    @MainActor private func updateLayout(_ input: Input) async {
        let items = input.items, area = input.area, obstacle = input.obstacle
        let result = await Task.detached(priority: .userInitiated) { AppStackLayout.groups(items, in: area, avoiding: obstacle) }.value
        guard !Task.isCancelled else { return }
        // Pointer movement only changes zIndex. Layout work happens solely when
        // the inventory, available area or settled history-panel position changes.
        withAnimation(reduceMotion || groups.isEmpty ? nil : .easeInOut(duration: 0.38)) { groups = result }
    }
    private func layer(for id: UInt32, in group: AppStackLayout.Group) -> Double {
        if hovered == id { return Double(group.ids.count + 2) }
        if fronts[group.app] == id { return Double(group.ids.count + 1) }
        return Double(group.ids.count - (group.ids.firstIndex(of: id) ?? group.ids.count))
    }
}
