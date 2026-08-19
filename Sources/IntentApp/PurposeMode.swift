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
            GraphTheme.background(colorScheme).opacity(0.86)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Label("PURPOSE MODE", systemImage: "scope")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                    Spacer()
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                }
                .padding(.horizontal, 34)
                .padding(.top, 28)

                Spacer()

                VStack(spacing: 18) {
                    Image(systemName: "scope")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(GraphTheme.editBlue)

                    Text("What do you want to use your computer for?")
                        .font(.system(size: 35, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GraphTheme.text(colorScheme))
                        .frame(maxWidth: 760)

                    Text("Say it naturally. Intent will reuse a matching intention or build a focused session for this task.")
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GraphTheme.muted(colorScheme))
                        .frame(maxWidth: 600)

                    HStack(spacing: 7) {
                        example("Reply to messages")
                        example("Work on data science")
                        example("Write my assignment")
                    }
                }

                Spacer()

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            speech.toggle()
                        } label: {
                            Image(systemName: speech.isListening ? "waveform" : "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(speech.isListening ? Color.white : GraphTheme.text(colorScheme))
                                .frame(width: 42, height: 42)
                                .background(
                                    speech.isListening ? GraphTheme.editBlue : GraphTheme.elevatedSurface(colorScheme),
                                    in: Circle()
                                )
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(speech.isListening ? "Stop listening" : "Speak your purpose")

                        TextField("What are you here to do?", text: $purpose)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .medium))
                            .focused($purposeFocused)
                            .onSubmit(submit)

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
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 760)
                    .frame(height: 62)
                    .adaptiveGlassPanel(colorScheme: colorScheme, cornerRadius: 22)

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
                .padding(.bottom, 52)
            }
        }
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
        Task {
            await model.startPurposeSession(for: request)
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
