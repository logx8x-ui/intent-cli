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

struct PurposeModeView: View {
    @EnvironmentObject private var model: IntentAppModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var speech = PurposeSpeechRecognizer()
    @State private var purpose = ""
    @FocusState private var purposeFocused: Bool

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

                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(GraphTheme.editBlue)
                            .frame(width: 28)

                        TextField("Describe the one thing you came here to do", text: $purpose)
                            .textFieldStyle(.plain)
                            .font(.system(size: 17, weight: .medium))
                            .focused($purposeFocused)
                            .onSubmit(submit)

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
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 820)
                    .frame(height: 68)
                    .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 24)
                    .shadow(color: Color.black.opacity(0.28), radius: 24, y: 10)

                    if hasLiveRecognition {
                        liveRecognitionPanel
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        HStack(spacing: 7) {
                            example("Reply to messages")
                            example("Work on data science")
                            example("Write my assignment")
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
                .frame(maxWidth: 900)

                Spacer()

                Text("Intent checks your saved intentions first, then builds the smallest focused session needed.")
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
            purpose = transcript
        }
    }

    private var cleanedPurpose: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasLiveRecognition: Bool {
        !recognizedIntentions.isEmpty || !recognizedApps.isEmpty || !removedApps.isEmpty
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
        guard cleanedPurpose.count >= 2 else { return [] }
        let excluded = Set(liveInterpretation.excludedIntentionIDs)
        let directlyIncluded = liveInterpretation.includedIntentionIDs.compactMap { id in
            model.intentions.first { $0.id == id }
        }
        let directIDs = Set(directlyIncluded.map(\.id))
        let fuzzyMatches = model.intentions
            .filter { !excluded.contains($0.id) && !directIDs.contains($0.id) }
            .compactMap { intention -> (Intention, Double)? in
                let score = recognitionScore(query: cleanedPurpose, candidate: intention.name)
                return score >= 0.42 ? (intention, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
                }
                return lhs.1 > rhs.1
            }
            .map(\.0)
        return Array((directlyIncluded + fuzzyMatches).prefix(3))
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

            HStack(spacing: 9) {
                ForEach(recognizedIntentions) { intention in
                    recognizedIntentionCard(intention)
                }
                ForEach(recognizedApps) { app in
                    recognizedAppCard(app)
                }
            }

            if !removedApps.isEmpty {
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
                }
                .transition(.opacity)
            }
        }
        .padding(13)
        .frame(maxWidth: 820, alignment: .leading)
        .background(GraphTheme.surface(colorScheme).opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(GraphTheme.stroke(colorScheme), lineWidth: 0.8))
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
                    .lineLimit(1)
                Text("Saved intention")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(GraphTheme.muted(colorScheme))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GraphTheme.editBlue.opacity(0.35), lineWidth: 0.8))
    }

    private func recognizedAppCard(_ app: InstalledApp) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 25, height: 25)
            Text(app.name)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 55)
        }
        .frame(width: 58, height: 46)
        .background(GraphTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GraphTheme.stroke(colorScheme), lineWidth: 0.7))
        .help("Installed app: \(app.name)")
    }

    private func recognitionScore(query: String, candidate: String) -> Double {
        let queryText = normalized(query)
        let candidateText = normalized(candidate)
        guard !queryText.isEmpty, !candidateText.isEmpty else { return 0 }
        if queryText == candidateText { return 1 }
        if queryText.contains(candidateText) { return 0.98 }

        let queryTokens = Set(queryText.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidateText.split(separator: " ").map(String.init))
        let overlap = queryTokens.intersection(candidateTokens).count
        guard overlap > 0 else {
            let finalToken = queryText.split(separator: " ").last.map(String.init) ?? ""
            return finalToken.count >= 3 && candidateTokens.contains(where: { $0.hasPrefix(finalToken) }) ? 0.55 : 0
        }
        return Double(overlap) / Double(max(1, candidateTokens.count))
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
