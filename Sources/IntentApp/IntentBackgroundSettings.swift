import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum IntentBackgroundChoice: String, CaseIterable, Identifiable {
    case none
    case knightCauseway
    case celestialGuardian
    case abbeyPlanners
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Adaptive glass"
        case .knightCauseway: "The Causeway"
        case .celestialGuardian: "The Guardian"
        case .abbeyPlanners: "The Abbey"
        case .custom: "Your image"
        }
    }

    var assetName: String? {
        switch self {
        case .knightCauseway: "knight-causeway"
        case .celestialGuardian: "celestial-guardian"
        case .abbeyPlanners: "abbey-planners"
        case .none, .custom: nil
        }
    }
}

struct BackgroundArtworkView: View {
    let selection: IntentBackgroundChoice
    let revision: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = IntentBackgroundStore.image(for: selection) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 1.2)
                    .opacity(colorScheme == .dark ? 0.36 : 0.52)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.08 : 0.035))
            } else {
                Color.clear
            }
        }
        .id("\(selection.rawValue)-\(revision)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

struct IntentSettingsView: View {
    @Binding var appearance: String
    @Binding var backgroundSelection: String
    @Binding var requireManualFinishBeforeSwitching: Bool
    @Binding var overlayShortcut: OverlayShortcut
    @Binding var finishShortcut: OverlayShortcut
    @Binding var launchAtLogin: Bool
    let onBackgroundChanged: () -> Void
    let onShowGuide: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTarget = false
    @State private var importError: String?

    private let presetColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "gearshape")
                Text("Settings")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("APPEARANCE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                Picker("Appearance", selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("BACKGROUND")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                LazyVGrid(columns: presetColumns, spacing: 8) {
                    ForEach(IntentBackgroundChoice.allCases.filter { $0 != .custom }) { choice in
                        backgroundButton(choice)
                    }
                    if IntentBackgroundStore.customImageExists {
                        backgroundButton(.custom)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        chooseImage()
                    } label: {
                        Label("Choose", systemImage: "photo")
                    }

                    Button {
                        pasteImage()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                    Text("Drop an image here")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(isDropTarget ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(GraphTheme.surface(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            isDropTarget ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isDropTarget) { providers in
                    importFromDrop(providers)
                }

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Intent keeps the same glass, blur, stars, and transparency over every background.")
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("SHORTCUT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                OverlayShortcutRecorder(
                    shortcut: $overlayShortcut,
                    onUpdate: IntentRuntime.shared.updateOverlayShortcut
                )

                Text("Opens or hides Intent anywhere on your Mac.")
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                Text("FINISH INTENTION")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
                    .padding(.top, 6)

                OverlayShortcutRecorder(
                    shortcut: $finishShortcut,
                    onUpdate: IntentRuntime.shared.updateFinishShortcut
                )

                Text("Ends the active intention unless a Timer is locking it.")
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("SESSIONS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))

                Toggle("Require finish before switching", isOn: $requireManualFinishBeforeSwitching)
                    .toggleStyle(.switch)

                Toggle("Open Intent at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { enabled in
                        if let message = IntentRuntime.shared.updateLaunchAtLogin(enabled) {
                            importError = message
                        }
                    }

                Text("When off, clicking another intention ends the current session and starts the new one.")
                    .font(.caption2)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            Divider()

            Button(action: onShowGuide) {
                Label("Show quick guide", systemImage: "questionmark.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 390)
        .background(GraphTheme.background(colorScheme).opacity(0.94))
    }

    private func backgroundButton(_ choice: IntentBackgroundChoice) -> some View {
        let selected = backgroundSelection == choice.rawValue
        return Button {
            backgroundSelection = choice.rawValue
            onBackgroundChanged()
        } label: {
            ZStack(alignment: .bottomLeading) {
                preview(for: choice)
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.76)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Text(choice.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: selected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func preview(for choice: IntentBackgroundChoice) -> some View {
        if choice == .none {
            ZStack {
                GraphTheme.background(colorScheme)
                Image(systemName: "circle.dotted")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
        } else if let image = IntentBackgroundStore.image(for: choice) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            GraphTheme.surface(colorScheme)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(at: url)
    }

    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard) {
            saveCustom(image)
            return
        }

        guard let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            importError = "Copy an image, image file, or image URL first."
            return
        }

        if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    await MainActor.run {
                        guard let image = NSImage(data: data) else {
                            importError = "That URL did not contain a readable image."
                            return
                        }
                        saveCustom(image)
                    }
                } catch {
                    await MainActor.run { importError = "That image URL could not be loaded." }
                }
            }
            return
        }

        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        importImage(at: url)
    }

    private func importFromDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let raw = String(data: data, encoding: .utf8),
                      let url = URL(string: raw) else { return }
                DispatchQueue.main.async { importImage(at: url) }
            }
            return true
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { saveCustom(image) }
        }
        return true
    }

    private func importImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            importError = "That file is not a readable image."
            return
        }
        saveCustom(image)
    }

    private func saveCustom(_ image: NSImage) {
        do {
            try IntentBackgroundStore.saveCustomImage(image)
            backgroundSelection = IntentBackgroundChoice.custom.rawValue
            importError = nil
            onBackgroundChanged()
        } catch {
            importError = "Intent could not save that image."
        }
    }
}

private struct OverlayShortcutRecorder: View {
    @Binding var shortcut: OverlayShortcut
    let onUpdate: (OverlayShortcut) -> String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isRecording = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                validationMessage = nil
                isRecording = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isRecording ? "keyboard.badge.ellipsis" : "keyboard")
                        .foregroundStyle(isRecording ? GraphTheme.editBlue : GraphTheme.muted(colorScheme))

                    Text(isRecording ? "Press a new shortcut" : shortcut.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))

                    Spacer()

                    Text(isRecording ? "ESC TO CANCEL" : "CHANGE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(GraphTheme.surface(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isRecording ? GraphTheme.editBlue : GraphTheme.stroke(colorScheme), lineWidth: isRecording ? 1.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))

            ShortcutKeyMonitor(isActive: $isRecording) { event in
                let candidate = OverlayShortcut(event: event)
                if let message = onUpdate(candidate) {
                    validationMessage = message
                    NSSound.beep()
                } else {
                    shortcut = candidate
                    validationMessage = nil
                }
                isRecording = false
            }
            .frame(width: 0, height: 0)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { isRecording = false }
    }
}

private struct ShortcutKeyMonitor: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (NSEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive, onCapture: onCapture)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = $isActive
        context.coordinator.onCapture = onCapture
        context.coordinator.setMonitoring(isActive)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setMonitoring(false)
    }

    final class Coordinator {
        var isActive: Binding<Bool>
        var onCapture: (NSEvent) -> Void
        private var monitor: Any?

        init(isActive: Binding<Bool>, onCapture: @escaping (NSEvent) -> Void) {
            self.isActive = isActive
            self.onCapture = onCapture
        }

        func setMonitoring(_ shouldMonitor: Bool) {
            if shouldMonitor, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if event.keyCode == UInt16(kVK_Escape) {
                        self.isActive.wrappedValue = false
                    } else {
                        self.onCapture(event)
                    }
                    return nil
                }
            } else if !shouldMonitor, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

enum IntentBackgroundStore {
    private static let imageCache = NSCache<NSString, NSImage>()

    static let customImageURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".intent", isDirectory: true)
        .appendingPathComponent("backgrounds", isDirectory: true)
        .appendingPathComponent("custom-background.png")

    static var customImageExists: Bool {
        FileManager.default.fileExists(atPath: customImageURL.path)
    }

    static func image(for choice: IntentBackgroundChoice) -> NSImage? {
        let cacheKey = choice.rawValue as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        if choice == .custom {
            guard let image = NSImage(contentsOf: customImageURL) else { return nil }
            imageCache.setObject(image, forKey: cacheKey)
            return image
        }
        guard let assetName = choice.assetName,
              let resourceBundle,
              let url = resourceBundle.url(forResource: assetName, withExtension: "png", subdirectory: "Backgrounds")
                ?? resourceBundle.url(forResource: assetName, withExtension: "png") else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static var resourceBundle: Bundle? {
        let bundleName = "Intent_IntentApp.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName)
        ].compactMap { $0 }
        return candidates.lazy.compactMap(Bundle.init(url:)).first
    }

    static func saveCustomImage(_ image: NSImage) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw IntentBackgroundError.invalidImage
        }
        try FileManager.default.createDirectory(
            at: customImageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: customImageURL, options: .atomic)
        imageCache.removeObject(forKey: IntentBackgroundChoice.custom.rawValue as NSString)
    }
}

private enum IntentBackgroundError: Error {
    case invalidImage
}
