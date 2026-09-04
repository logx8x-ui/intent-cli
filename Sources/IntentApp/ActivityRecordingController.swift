import AppKit
import Foundation
import IntentCore

@MainActor
final class ActivityRecordingController: ObservableObject {
    @Published private(set) var state: ActivityRecordingState?
    @Published var errorMessage: String?

    private let store: ActivityRecordingStore
    private var timer: Timer?
    private var observersInstalled = false
    private var trackedBundleIdentifier: String?
    private var sessionIsAvailable = true

    init(store: ActivityRecordingStore = ActivityRecordingStore()) {
        self.store = store
        state = store.load()

        if state?.isActive == true {
            if let endsAt = state?.endsAt, endsAt <= Date() {
                finish(at: endsAt)
            } else {
                trackedBundleIdentifier = Self.frontmostRecordableBundleIdentifier()
                installObservers()
                startTimer()
            }
        }
    }

    var isRecording: Bool { state?.isActive == true }
    var hasCompletedRecording: Bool { state?.isActive == false && state?.completedAt != nil }

    var statusText: String {
        guard let state else { return "Not recording" }
        if state.isActive {
            if let endsAt = state.endsAt {
                return "Recording · \(Self.durationText(until: endsAt)) remaining"
            }
            return "Recording until you stop it"
        }
        return "Ready to review"
    }

    var recordedTimeText: String {
        guard let seconds = state?.totalRecordedSeconds, seconds > 0 else { return "Less than a minute recorded" }
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min of app activity" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours) hr of app activity"
            : "\(hours) hr \(remainingMinutes) min of app activity"
    }

    func start(period: ActivityRecordingPeriod, now: Date = Date()) {
        let baseline = Dictionary(
            uniqueKeysWithValues: Self.currentWebsiteCounts().map { key, count in
                (ActivityRecordingKey.baselineFingerprint(for: key), count)
            }
        )
        state = ActivityRecordingState(
            period: period,
            startedAt: now,
            websiteBaselineCounts: baseline
        )
        trackedBundleIdentifier = Self.frontmostRecordableBundleIdentifier()
        sessionIsAvailable = !Self.screenIsLocked
        errorMessage = nil
        persist()
        installObservers()
        startTimer()
    }

    func stop() {
        finish(at: Date())
    }

    func clear() {
        stopTimer()
        removeObservers()
        state = nil
        trackedBundleIdentifier = nil
        do {
            try store.clear()
            errorMessage = nil
        } catch {
            errorMessage = "Could not delete the recording data: \(error.localizedDescription)"
        }
    }

    func browserGuardIsConnected(browserBundleIdentifier: String) -> Bool {
        BrowserGuardStateStore(
            fileURL: BrowserGuardStateStore.fileURL(for: browserBundleIdentifier)
        ).isEnabled() && BrowserGuardHeartbeatStore(
            fileURL: BrowserGuardHeartbeatStore.fileURL(for: browserBundleIdentifier)
        ).isFresh(maxAge: 8)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer(
            timeInterval: 10,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: true
        )
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func timerDidFire() {
        sample(at: Date())
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(
                self,
                selector: #selector(sessionDidBecomeUnavailable),
                name: name,
                object: nil
            )
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(
                self,
                selector: #selector(sessionDidBecomeAvailable),
                name: name,
                object: nil
            )
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        sample(at: Date(), nextBundleIdentifier: Self.recordableBundleIdentifier(for: app))
    }

    @objc private func sessionDidBecomeUnavailable(_ notification: Notification) {
        sample(at: Date(), nextBundleIdentifier: nil)
        sessionIsAvailable = false
    }

    @objc private func sessionDidBecomeAvailable(_ notification: Notification) {
        sessionIsAvailable = true
        trackedBundleIdentifier = Self.frontmostRecordableBundleIdentifier()
        if var state {
            state.lastSampleAt = Date()
            self.state = state
            persist()
        }
    }

    private func removeObservers() {
        guard observersInstalled else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observersInstalled = false
    }

    private func sample(at now: Date, nextBundleIdentifier: String? = nil) {
        guard var state, state.isActive else { return }
        let elapsed = min(max(now.timeIntervalSince(state.lastSampleAt), 0), 15)
        if sessionIsAvailable, !Self.screenIsLocked, let trackedBundleIdentifier {
            state.recordApplication(bundleIdentifier: trackedBundleIdentifier, seconds: elapsed)
        }
        state.lastSampleAt = now
        state.updateWebsiteCounts(Self.currentWebsiteCounts())
        self.state = state
        trackedBundleIdentifier = nextBundleIdentifier ?? Self.frontmostRecordableBundleIdentifier()

        if let endsAt = state.endsAt, now >= endsAt {
            finish(at: endsAt, alreadySampled: true)
        } else {
            persist()
        }
    }

    private func finish(at date: Date, alreadySampled: Bool = false) {
        guard var state, state.isActive else { return }
        if !alreadySampled {
            sampleBeforeFinish(at: date, state: &state)
        }
        state.updateWebsiteCounts(Self.currentWebsiteCounts())
        state.finish(at: date)
        self.state = state
        persist()
        stopTimer()
        removeObservers()
        trackedBundleIdentifier = nil
    }

    private func sampleBeforeFinish(at date: Date, state: inout ActivityRecordingState) {
        let elapsed = min(max(date.timeIntervalSince(state.lastSampleAt), 0), 15)
        if sessionIsAvailable, !Self.screenIsLocked, let trackedBundleIdentifier {
            state.recordApplication(bundleIdentifier: trackedBundleIdentifier, seconds: elapsed)
        }
    }

    private func persist() {
        guard let state else { return }
        do {
            try store.save(state)
            errorMessage = nil
        } catch {
            errorMessage = "Recording is running, but its local data could not be saved: \(error.localizedDescription)"
        }
    }

    private static func frontmostRecordableBundleIdentifier() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return recordableBundleIdentifier(for: app)
    }

    private static func recordableBundleIdentifier(for app: NSRunningApplication) -> String? {
        guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
        return app.bundleIdentifier
    }

    private static func currentWebsiteCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for browserBundleIdentifier in BrowserApplication.bundleIdentifiers {
            for entry in PurposeWebsiteHistoryStore(
                browserBundleIdentifier: browserBundleIdentifier
            ).loadEntries() {
                counts[
                    ActivityRecordingKey.website(
                        browserBundleIdentifier: browserBundleIdentifier,
                        host: entry.value
                    )
                ] = entry.visitCount
            }
        }
        return counts
    }

    private static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func durationText(until endDate: Date) -> String {
        let seconds = max(0, Int(endDate.timeIntervalSinceNow))
        if seconds >= 86_400 {
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(max(1, seconds / 60))m"
    }
}
