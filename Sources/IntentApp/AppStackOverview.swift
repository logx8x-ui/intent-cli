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
    let card: (UInt32, CGRect, Bool) -> Card
    @State private var groups: [AppStackLayout.Group] = []
    @State private var layoutResolved = false
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
                collapsedGroup(group)
            }
            if let expanded, let group = groups.first(where: { $0.app == expanded }) {
                expandedGroup(group)
            } else if layoutResolved && groups.isEmpty && !items.isEmpty {
                // No lost windows when the display cannot fit readable clusters.
                expandedGroup(.init(app: "", ids: items.map(\.id), frame: area))
            }
        }
        .task(id: input) { await updateLayout(input) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
    }
    @MainActor private func updateLayout(_ input: Input) async {
        let items = input.items, area = input.area, obstacle = input.obstacle
        let result = await Task.detached(priority: .userInitiated) { AppStackLayout.groups(items, in: area, avoiding: obstacle) }.value
        guard !Task.isCancelled else { return }
        groups = result
        layoutResolved = true
    }
    private func ordered(_ group: AppStackLayout.Group) -> [UInt32] {
        guard let front = fronts[group.app], group.ids.contains(front) else { return group.ids }
        return [front] + group.ids.filter { $0 != front }
    }
    private func collapsedGroup(_ group: AppStackLayout.Group) -> some View {
        let ids = ordered(group)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ids.prefix(4).reversed()), id: \.self) { id in
                if let item = items.first(where: { $0.id == id }) {
                    card(id, frame(item, group: group, offset: ids.firstIndex(of: id) ?? 0), id == ids.first)
                        .opacity(expanded == nil || expanded == group.app ? 1 : 0.25)
                }
            }
            if ids.count > 1 {
                Button { expanded = group.app } label: {
                    Text("\(names[group.app] ?? group.app) · \(ids.filter { selected.contains($0) }.count) of \(ids.count) selected")
                        .font(.caption).padding(6).background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(.plain)
                    .onHover { if $0 && expanded == nil { expanded = group.app } }
                    .position(x: group.frame.midX, y: group.frame.maxY - 8)
            }
        }
    }
    private func frame(_ item: AppStackLayout.Item, group: AppStackLayout.Group, offset: Int) -> CGRect {
        let depth = CGFloat(min(3, group.ids.count - 1)) * 14
        let scale = min((group.frame.width - depth) / max(1, item.source.width),
                        (group.frame.height - depth - 56) / max(1, item.source.height))
        let inset = (group.frame.width - depth - item.source.width * scale) / 2
        return CGRect(x: group.frame.minX + inset + CGFloat(offset) * 14, y: group.frame.minY + CGFloat(offset) * 14,
                      width: item.source.width * scale, height: item.source.height * scale)
    }
    private func expandedGroup(_ group: AppStackLayout.Group) -> some View {
        let available = group.app.isEmpty && obstacle != nil ? FieldOfViewLayout.workspace(around: obstacle!, in: area) : area
        return VStack(spacing: 12) {
            HStack {
                Text(names[group.app] ?? "Open windows").font(.headline)
                Spacer()
                Button("Done · Esc") { expanded = nil }.buttonStyle(.bordered)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: min(230, max(110, available.width - 40))), spacing: 18)], spacing: 18) {
                    ForEach(ordered(group), id: \.self) { id in
                        if let item = items.first(where: { $0.id == id }) {
                            GeometryReader { proxy in
                                let scale = min((proxy.size.width - 8) / max(1, item.source.width), 172 / max(1, item.source.height))
                                card(id, CGRect(x: (proxy.size.width - item.source.width * scale) / 2, y: 0,
                                                width: item.source.width * scale, height: item.source.height * scale), true)
                            }.frame(height: 202)
                        }
                    }
                }
            }
        }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .frame(width: available.width, height: available.height)
            .position(x: available.midX, y: available.midY)
    }
}
