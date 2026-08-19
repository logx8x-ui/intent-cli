import AppKit
import AVFoundation
import Foundation
import IntentCore
import Speech
import SwiftUI

enum PurposeModePreference {
    static let key = "intentPurposeModeEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

struct PurposeSessionSaveCandidate: Identifiable {
    let id = UUID().uuidString
    var intention: Intention
    let statedPurpose: String
}

struct PurposeSessionUsage {
    var appBundleIdentifiers: Set<String>
    var websiteResourceIDs: Set<String>
}

@MainActor
final class PurposeSessionUsageTracker {
    private let intention: Intention
    private let workspace = NSWorkspace.shared
    private var activationObserver: NSObjectProtocol?
    private var pollingTimer: Timer?
    private var usedAppBundleIdentifiers = Set<String>()
    private var usedWebsiteResourceIDs = Set<String>()

    init(intention: Intention) {
        self.intention = intention
    }

    func start() {
        let allowed = Set(intention.allowedApps.map(\.bundleIdentifier))
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleIdentifier = app.bundleIdentifier,
                  allowed.contains(bundleIdentifier) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.usedAppBundleIdentifiers.insert(bundleIdentifier)
            }
        }

        if let bundleIdentifier = workspace.frontmostApplication?.bundleIdentifier,
           allowed.contains(bundleIdentifier) {
            usedAppBundleIdentifiers.insert(bundleIdentifier)
        }

        recordBrowserUsage()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordBrowserUsage()
            }
        }
    }

    func stop() -> PurposeSessionUsage {
        recordBrowserUsage()
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        return PurposeSessionUsage(
            appBundleIdentifiers: usedAppBundleIdentifiers,
            websiteResourceIDs: usedWebsiteResourceIDs
        )
    }

    private func recordBrowserUsage() {
        let websitesByBrowser = Dictionary(grouping: intention.allowedWebsites) {
            $0.browserBundleIdentifier ?? ""
        }
        for (browserBundleIdentifier, websites) in websitesByBrowser where !browserBundleIdentifier.isEmpty {
            guard let snapshot = BrowserTabSnapshotStore(browserBundleIdentifier: browserBundleIdentifier)
                .load(maxAge: 5) else {
                continue
            }
            for tab in snapshot.tabs where tab.active {
                let normalizedURL = AllowedWebsite.normalized(tab.url)
                for website in websites where Self.matches(normalizedURL, allowedWebsite: website.value) {
                    usedWebsiteResourceIDs.insert(website.resourceID)
                    usedAppBundleIdentifiers.insert(browserBundleIdentifier)
                }
            }
        }
    }

    private static func matches(_ normalizedURL: String, allowedWebsite: String) -> Bool {
        normalizedURL == allowedWebsite
            || normalizedURL.hasPrefix("\(allowedWebsite)/")
            || allowedWebsite.hasPrefix("\(normalizedURL)/")
    }
}

@MainActor
final class PurposeSpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false

    func toggle() {
        if isListening {
            stop()
        } else {
            Task { await beginListening() }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
    }

    func resetTranscript() {
        transcript = ""
    }

    private func beginListening() async {
        stop()
        errorMessage = nil

        guard await requestSpeechPermission() else {
            errorMessage = "Allow Speech Recognition for Intent in System Settings to use voice."
            return
        }
        guard await requestMicrophonePermission() else {
            errorMessage = "Allow Microphone access for Intent in System Settings to use voice."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is not available right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorMessage = "Intent could not access a microphone input."
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self?.stop()
                    }
                }
                if error != nil, self?.isListening == true {
                    self?.stop()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            stop()
            errorMessage = "Intent could not start listening: \(error.localizedDescription)"
        }
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private struct PurposePromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let intentions: [Intention]
    let colorScheme: ColorScheme
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        context.coordinator.apply(to: textView)
        context.coordinator.updateHeight(for: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            context.coordinator.isApplyingUpdate = false
        }
        context.coordinator.apply(to: textView)
        context.coordinator.updateHeight(for: textView, in: scrollView)
        scrollView.hasVerticalScroller = measuredHeight >= Coordinator.maximumHeight

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let minimumHeight: CGFloat = 44
        static let maximumHeight: CGFloat = 176

        var parent: PurposePromptEditor
        var isApplyingUpdate = false

        init(parent: PurposePromptEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            apply(to: textView)
            if let scrollView = textView.enclosingScrollView {
                updateHeight(for: textView, in: scrollView)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }

        func apply(to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            let baseColor = parent.colorScheme == .dark
                ? NSColor(calibratedWhite: 0.96, alpha: 1)
                : NSColor(calibratedWhite: 0.08, alpha: 1)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: baseColor
            ]

            isApplyingUpdate = true
            let storage = textView.textStorage ?? NSTextStorage()
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))

            let source = textView.string as NSString
            for intention in parent.intentions.sorted(by: { $0.name.count > $1.name.count }) {
                let escapedName = NSRegularExpression.escapedPattern(for: intention.name)
                let pattern = "(?i)\\*(?:\\s+(?:the|intention|called|named))*\\s+(\(escapedName))(?=$|[^A-Za-z0-9])"
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in expression.matches(in: textView.string, range: NSRange(location: 0, length: source.length)) {
                    let nameRange = match.range(at: 1)
                    guard nameRange.location != NSNotFound else { continue }
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemIndigo,
                        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.systemIndigo
                    ], range: nameRange)
                }
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
            textView.selectedRanges = selectedRanges
            isApplyingUpdate = false
        }

        func updateHeight(for textView: NSTextView, in scrollView: NSScrollView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let availableWidth = max(scrollView.contentSize.width, 280)
            textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            let nextHeight = min(max(Self.minimumHeight, ceil(usedHeight)), Self.maximumHeight)
            guard abs(parent.measuredHeight - nextHeight) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.measuredHeight - nextHeight) > 0.5 else { return }
                self.parent.measuredHeight = nextHeight
            }
        }
    }
}

private enum PurposeWebsiteIconLibrary {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let image = cache[name] { return image }
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "WebsiteIcons")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

struct PurposeModeView: View {
    @EnvironmentObject private var model: IntentAppModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var speech = PurposeSpeechRecognizer()
    @State private var purpose = ""
    @State private var purposeFocused = false
    @State private var promptHeight: CGFloat = 44

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            GraphTheme.background(colorScheme).opacity(0.9)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Label("PURPOSE MODE", systemImage: "scope")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                    Spacer()
                    Button(action: onDismiss) {
                        HStack(spacing: 7) {
                            Text("⇧ X")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .frame(height: 21)
                                .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 6))
                            Text("close")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 34)
                .padding(.top, 28)

                Spacer()

                VStack(spacing: 22) {
                    ZStack {
                        Circle()
                            .fill(GraphTheme.elevatedSurface(colorScheme))
                            .frame(width: 58, height: 58)
                        Circle()
                            .stroke(GraphTheme.editBlue.opacity(0.65), lineWidth: 1)
                            .frame(width: 58, height: 58)
                        Image(systemName: "scope")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(GraphTheme.text(colorScheme))
                    }

                    Text("What do you want to use your computer for?")
                        .font(.system(size: 38, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GraphTheme.text(colorScheme))
                        .frame(maxWidth: 820)

                    HStack(alignment: .bottom, spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(GraphTheme.editBlue)
                            .frame(width: 28)
                            .frame(height: 40)

                        ZStack(alignment: .topLeading) {
                            if purpose.isEmpty {
                                Text("Describe the one thing you came here to do")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(GraphTheme.muted(colorScheme))
                                    .padding(.top, 11)
                                    .allowsHitTesting(false)
                            }
                            PurposePromptEditor(
                                text: $purpose,
                                measuredHeight: $promptHeight,
                                isFocused: $purposeFocused,
                                intentions: model.intentions,
                                colorScheme: colorScheme,
                                onSubmit: submit
                            )
                            .frame(height: promptHeight)
                        }

                        Button {
                            speech.toggle()
                        } label: {
                            Image(systemName: speech.isListening ? "waveform" : "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(speech.isListening ? Color.white : GraphTheme.text(colorScheme))
                                .frame(width: 40, height: 40)
                                .background(
                                    speech.isListening ? GraphTheme.editBlue : GraphTheme.elevatedSurface(colorScheme),
                                    in: Circle()
                                )
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(speech.isListening ? "Stop listening" : "Speak your purpose")
                        .frame(height: 40)

                        Button(action: submit) {
                            Group {
                                if model.purposeModeIsResolving {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 14, weight: .bold))
                                }
                            }
                            .frame(width: 38, height: 38)
                            .background(GraphTheme.editBlue, in: Circle())
                            .foregroundStyle(.white)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(cleanedPurpose.isEmpty || model.purposeModeIsResolving)
                        .frame(height: 40)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 940)
                    .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 24)
                    .shadow(color: Color.black.opacity(0.28), radius: 24, y: 10)

                    if hasLiveRecognition {
                        liveRecognitionPanel
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        HStack(spacing: 7) {
                            example("Use Firefox with YouTube")
                            example("Reply with Messages")
                            example("Study with RemNote and Anki")
                        }
                        .transition(.opacity)
                    }

                    if speech.isListening {
                        Text("Listening...")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(GraphTheme.editBlue)
                    } else if let message = speech.errorMessage ?? model.purposeModeError {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 1020)

                Spacer()

                Text("Use * before a saved intention name. Otherwise, Intent builds the smallest focused session from the apps and websites you mention.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme).opacity(0.72))
                    .padding(.bottom, 28)
            }
            .padding(.top, 52)
        }
        .animation(.easeOut(duration: 0.18), value: hasLiveRecognition)
        .onAppear {
            purposeFocused = true
            model.purposeModeError = nil
        }
        .onDisappear { speech.stop() }
        .onChange(of: speech.transcript) { transcript in
            guard speech.isListening || !transcript.isEmpty else { return }
            purpose = PurposeLiveInterpreter.canonicalizedDisplayText(transcript)
        }
        .onChange(of: purpose) { value in
            let canonical = PurposeLiveInterpreter.canonicalizedDisplayText(value)
            if canonical != value {
                purpose = canonical
                return
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !speech.isListening {
                speech.resetTranscript()
            }
            model.purposeModeError = nil
        }
    }

    private var cleanedPurpose: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasLiveRecognition: Bool {
        !recognizedIntentions.isEmpty
            || !recognizedApps.isEmpty
            || !recognizedWebsites.isEmpty
            || !removedApps.isEmpty
            || !removedWebsites.isEmpty
    }

    private var liveInterpretation: PurposeLiveInterpretation {
        PurposeLiveInterpreter.interpret(
            cleanedPurpose,
            apps: model.installedApps.map {
                AllowedApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier)
            },
            intentions: model.intentions
        )
    }

    private var recognizedIntentions: [Intention] {
        liveInterpretation.includedIntentionIDs.compactMap { id in
            model.intentions.first { $0.id == id }
        }
    }

    private var recognizedApps: [InstalledApp] {
        guard cleanedPurpose.count >= 2 else { return [] }
        let interpretation = liveInterpretation
        let excludedIDs = Set(interpretation.excludedAppBundleIdentifiers)
        let intentionAppIDs = Set(recognizedIntentions.flatMap { $0.allowedApps.map(\.bundleIdentifier) })
        let combinedIDs = intentionAppIDs
            .union(interpretation.includedAppBundleIdentifiers)
            .subtracting(excludedIDs)
        let explicitIDs = Set(interpretation.explicitlyIncludedAppBundleIdentifiers)
        return model.installedApps
            .filter { combinedIDs.contains($0.bundleIdentifier) }
            .sorted { lhs, rhs in
                let lhsExplicit = explicitIDs.contains(lhs.bundleIdentifier)
                let rhsExplicit = explicitIDs.contains(rhs.bundleIdentifier)
                if lhsExplicit != rhsExplicit { return lhsExplicit }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    private var removedApps: [InstalledApp] {
        let removedIDs = Set(liveInterpretation.excludedAppBundleIdentifiers)
        return model.installedApps
            .filter { removedIDs.contains($0.bundleIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var recognizedWebsites: [PurposeWebsiteSelection] {
        liveInterpretation.includedWebsites
    }

    private var removedWebsites: [PurposeWebsiteSelection] {
        liveInterpretation.excludedWebsites
    }

    private var recognitionAnimationKey: String {
        let intentionIDs = recognizedIntentions.map(\.id)
        let appIDs = recognizedApps.map(\.bundleIdentifier)
        let websiteIDs = recognizedWebsites.map(\.id)
        return (intentionIDs + appIDs + websiteIDs).joined(separator: "|")
    }

    private var liveRecognitionPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("INTENT UNDERSTANDS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76, maximum: 148), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(recognizedIntentions) { intention in
                    recognizedIntentionCard(intention)
                        .transition(.scale(scale: 0.76).combined(with: .opacity))
                }
                ForEach(recognizedApps) { app in
                    recognizedAppCard(app)
                        .transition(.scale(scale: 0.76).combined(with: .opacity))
                }
                ForEach(recognizedWebsites) { website in
                    recognizedWebsiteCard(website)
                        .transition(.scale(scale: 0.76).combined(with: .opacity))
                }
            }

            if !removedApps.isEmpty || !removedWebsites.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.red.opacity(0.86))
                    Text("REMOVED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                    ForEach(removedApps) { app in
                        Text(app.name)
                            .font(.system(size: 10, weight: .semibold))
                            .strikethrough()
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                    }
                    ForEach(removedWebsites) { website in
                        Text(website.name)
                            .font(.system(size: 10, weight: .semibold))
                            .strikethrough()
                            .foregroundStyle(GraphTheme.muted(colorScheme))
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: 940, minHeight: 124, alignment: .topLeading)
        .background(GraphTheme.surface(colorScheme).opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(GraphTheme.stroke(colorScheme), lineWidth: 0.8))
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: recognitionAnimationKey)
    }

    private func recognizedIntentionCard(_ intention: Intention) -> some View {
        HStack(spacing: 8) {
            Image(systemName: intention.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GraphTheme.editBlue)
                .frame(width: 26, height: 26)
                .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(intention.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .underline()
                    .lineLimit(1)
                Text("Saved intention")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 132, minHeight: 62)
        .background(Color.indigo.opacity(colorScheme == .dark ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.indigo.opacity(0.8), lineWidth: 1.2))
    }

    private func recognizedAppCard(_ app: InstalledApp) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
            Text(app.name)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 76)
        }
        .frame(minWidth: 76, minHeight: 64)
        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GraphTheme.stroke(colorScheme), lineWidth: 0.7))
        .help("Installed app: \(app.name)")
    }

    private func recognizedWebsiteCard(_ website: PurposeWebsiteSelection) -> some View {
        VStack(spacing: 4) {
            if let resource = PurposeWebsiteCatalog.website(for: website.value)?.iconResource,
               let image = PurposeWebsiteIconLibrary.image(named: resource) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(GraphTheme.editBlue)
                    .frame(width: 34, height: 34)
            }
            Text(website.name)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 90)
        }
        .frame(minWidth: 82, minHeight: 64)
        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GraphTheme.editBlue.opacity(0.48), lineWidth: 0.9))
        .help("Allowed website: \(website.value)")
    }

    private func example(_ title: String) -> some View {
        Button(title) {
            purpose = title
            purposeFocused = true
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(GraphTheme.muted(colorScheme))
        .padding(.horizontal, 11)
        .frame(height: 27)
        .background(GraphTheme.surface(colorScheme), in: Capsule())
        .overlay(Capsule().stroke(GraphTheme.stroke(colorScheme)))
    }

    private func submit() {
        guard !cleanedPurpose.isEmpty, !model.purposeModeIsResolving else { return }
        speech.stop()
        let request = cleanedPurpose
        let interpretation = liveInterpretation
        Task {
            await model.startPurposeSession(for: request, liveInterpretation: interpretation)
        }
    }
}

struct PurposeSessionSaveSheet: View {
    @EnvironmentObject private var model: IntentAppModel
    @Environment(\.colorScheme) private var colorScheme
    let candidate: PurposeSessionSaveCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(GraphTheme.editBlue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save this session as an intention?")
                        .font(.system(size: 20, weight: .semibold))
                    Text(candidate.intention.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
            }

            Text("Intent kept the apps and websites used for \"\(candidate.statedPurpose)\". Saving makes this setup available instantly next time.")
                .font(.system(size: 13))
                .foregroundStyle(GraphTheme.muted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                resourceCount(
                    candidate.intention.allowedApps.count,
                    label: candidate.intention.allowedApps.count == 1 ? "app" : "apps",
                    icon: "app"
                )
                resourceCount(
                    candidate.intention.allowedWebsites.count,
                    label: candidate.intention.allowedWebsites.count == 1 ? "website" : "websites",
                    icon: "globe"
                )
            }

            HStack {
                Button("No, forget it") {
                    model.discardPurposeSessionCandidate()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Yes, save intention") {
                    model.savePurposeSessionCandidate()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(GraphTheme.background(colorScheme))
    }

    private func resourceCount(_ count: Int, label: String, icon: String) -> some View {
        Label("\(count) \(label)", systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(GraphTheme.surface(colorScheme), in: Capsule())
            .overlay(Capsule().stroke(GraphTheme.stroke(colorScheme)))
    }
}
