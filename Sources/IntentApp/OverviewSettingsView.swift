import AppKit
import IntentCore
import SwiftUI

struct AppPresetStatusStrip: View {
    @ObservedObject var model: IntentAppModel
    let openSettings: () -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                group("Always allowed", apps: model.alwaysAllowedApps, color: .green)
                group("Always blocked", apps: model.alwaysBlockedApps, color: .red)
            }
        }
    }
    private func group(_ title: String, apps: [AllowedApp], color: Color) -> some View {
        Button(action: openSettings) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10, weight: .medium))
                if apps.isEmpty { Text("None").font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(apps, id: \.bundleIdentifier) { app in
                    Image(nsImage: presetIcon(app.bundleIdentifier)).resizable().frame(width: 19, height: 19)
                        .help("\(app.name) · \(title.lowercased())")
                }
            }.padding(.horizontal, 8).padding(.vertical, 3).background(.ultraThinMaterial, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("\(title): \(apps.map(\.name).joined(separator: ", "))")
    }
}

struct OverviewSettingsView: View {
    @ObservedObject var model: IntentAppModel
    @State private var query = ""
    @AppStorage("overviewShowClock") private var showClock = true
    @AppStorage("overviewShowTitles") private var showTitles = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2.weight(.semibold))
            ScrollView { IntentWorkPeriodSettings(model: model).padding(.trailing, 6) }.frame(maxHeight: 260)
            HStack { Toggle("Show clock", isOn: $showClock); Spacer(); Toggle("Window titles", isOn: $showTitles) }.font(.caption)
            Divider()
            Text("App defaults").font(.headline)
            Text("Apply to every intention in either mode. These apps stay out of the overview. Blocking hides access; it never closes the app.")
                .font(.caption).foregroundStyle(.secondary)
            presetList("Always allowed", apps: model.alwaysAllowedApps, color: .green, remove: model.toggleAlwaysAllowedApp)
            presetList("Always blocked", apps: model.alwaysBlockedApps, color: .red, remove: model.toggleAlwaysBlockedApp)
            TextField("Find an app to add…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.installedApps.filter { $0.matchesSearch(query) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                            Text(app.name).lineLimit(1).font(.callout)
                            Spacer()
                            let item = AllowedApp(name: app.name, bundleIdentifier: app.bundleIdentifier)
                            Button(model.isAlwaysAllowed(app.bundleIdentifier) ? "Allowed ✓" : "Allow") { model.toggleAlwaysAllowedApp(item) }
                                .tint(.green).help("Always allow \(app.name)")
                            Button(model.alwaysBlockedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) ? "Blocked ✓" : "Block") { model.toggleAlwaysBlockedApp(item) }
                                .tint(.red).help("Always block \(app.name)")
                        }.buttonStyle(.bordered).controlSize(.small).padding(.vertical, 2)
                    }
                }
            }.frame(height: 160)
            Text("Choosing Allow or Block moves an app between lists. Remove it with × to choose it separately each time.").font(.caption2).foregroundStyle(.secondary)
        }.disabled(model.hasActiveSession)
    }
    private func presetList(_ title: String, apps: [AllowedApp], color: Color, remove: @escaping (AllowedApp) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if apps.isEmpty { Text("None yet").font(.caption).foregroundStyle(.secondary) }
                    ForEach(apps, id: \.bundleIdentifier) { app in
                        HStack(spacing: 5) {
                            Image(nsImage: presetIcon(app.bundleIdentifier)).resizable().frame(width: 19, height: 19)
                            Text(app.name).font(.caption)
                            Button { remove(app) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(app.name) from \(title.lowercased())")
                        }.padding(7).background(color.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }
}

private func presetIcon(_ bundle: String) -> NSImage {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
        return NSImage(named: NSImage.applicationIconName)!
    }
    return NSWorkspace.shared.icon(forFile: url.path)
}
