import SwiftUI

/// App-only search in the overview. Every result has a real installed bundle URL.
struct OverviewAppSearch: View {
    @ObservedObject var controller: QuickSelectionController
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.65))
                TextField("Search an app to add", text: $controller.appSearchQuery)
                    .textFieldStyle(.plain).font(.system(size: 24))
                    .focused($focused).accessibilityLabel("Search apps for this intention")
                    .onChange(of: controller.appSearchQuery) { _ in controller.appSearchIndex = 0 }
                Text("esc").font(.caption).foregroundStyle(.white.opacity(0.5))
            }.padding(20)
            if !controller.appSearchQuery.isEmpty {
                Divider().overlay(.white.opacity(0.12))
                let results = Array(controller.appSearchResults.prefix(7))
                if results.isEmpty {
                    Text("No matching apps").foregroundStyle(.white.opacity(0.7)).padding(20)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                    Button { controller.chooseSearchApplication(app) } label: {
                        HStack(spacing: 14) {
                            Image(nsImage: app.icon).resizable().frame(width: 38, height: 38)
                            Text(app.name).font(.system(size: 18, weight: .medium))
                            Spacer()
                            if index == controller.appSearchIndex { Image(systemName: "return").foregroundStyle(.white.opacity(0.65)) }
                        }.padding(.horizontal, 20).padding(.vertical, 10)
                            .background(index == controller.appSearchIndex ? Color.white.opacity(0.13) : .clear)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Add \(app.name) to intention")
                }
                Text(controller.selection.accessMode == .blacklist ? "Enter adds the app to your blocked selection" : "Enter adds the app to your allowed selection")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(12)
            }
        }.foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .onAppear { focused = true }
    }
}
