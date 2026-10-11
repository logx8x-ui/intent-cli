import AppKit
import Combine
import Darwin
import IntentCore

/// Both channels can be installed, but global input and Browser Guard have a
/// single owner. An explicit app launch hands off only an idle engine.
@MainActor
final class IntentChannelRuntimeCoordinator {
    static let shared = IntentChannelRuntimeCoordinator()
    private let lease = IntentEngineLease()
    private var switchObserver: NSObjectProtocol?
    private var sessionObserver: AnyCancellable?
    private weak var model: IntentAppModel?
    private(set) var acquired = false
    private var handlingLeaseFailure = false

    func acquireBeforeRuntime() -> Bool {
        guard !IntentEnvironment.isQA else { return true }
        if IntentEngineLease.currentOwner() == nil,
           let legacy = [IntentBuildChannel.launch, .development].flatMap({ channel in
               NSRunningApplication.runningApplications(withBundleIdentifier: channel.bundleIdentifier)
           }).first(where: { !$0.isTerminated && $0.processIdentifier != getpid() }) {
            // A pre-channel app owns global input without participating in the
            // lease protocol. Never initialize a second engine beside it.
            let alert = NSAlert()
            alert.messageText = "Close the previous Intent app before switching"
            let location = legacy.bundleURL?.path ?? legacy.localizedName ?? "the other Intent app"
            alert.informativeText = "Finish any active intention, then close \(location) and reopen \(IntentBuildChannel.current.appName). Your saved intentions remain unchanged."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        do {
            try lease.acquire()
            acquired = true
            return true
        } catch IntentEngineLeaseError.busy(let owner) {
            guard let owner, !owner.activeSession,
                  owner.bundleIdentifier != Bundle.main.bundleIdentifier else {
                explainBusy(owner)
                return false
            }
            DistributedNotificationCenter.default().postNotificationName(
                .init(IntentEngineLease.switchNotificationName), object: nil,
                userInfo: ["generation": owner.generation.uuidString,
                           "requester": IntentBuildChannel.current.bundleIdentifier],
                deliverImmediately: true)
            // The other process services its own main queue. A bounded retry
            // never steals its advisory lock or kills an active intention.
            let deadline = Date().addingTimeInterval(3)
            repeat {
                Thread.sleep(forTimeInterval: 0.05)
                // Wait for the old process to exit as well as for its lease.
                // Carbon/input resources may outlive applicationWillTerminate.
                if Darwin.kill(owner.pid, 0) == 0 || errno == EPERM { continue }
                do {
                    try lease.acquire()
                    acquired = true
                    return true
                } catch IntentEngineLeaseError.busy { continue }
                catch { explain(error); return false }
            } while Date() < deadline
            explainBusy(IntentEngineLease.currentOwner())
            return false
        } catch { explain(error); return false }
    }

    func observe(_ model: IntentAppModel) {
        guard acquired else { return }
        self.model = model
        sessionObserver = model.$activeSessionName.combineLatest(model.$zeroDriftEndsAt)
            .sink { [weak self] name, workEnd in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    do { try self.lease.updateActiveSession(name != nil || workEnd.map { $0 > Date() } == true) }
                    catch {
                        guard !self.handlingLeaseFailure else { return }
                        self.handlingLeaseFailure = true
                        // Never continue enforcing with a browser transport
                        // which belongs to another channel.
                        model.emergencyStop(showMessage: false)
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
        switchObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init(IntentEngineLease.switchNotificationName), object: nil,
            queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.lease.isOwner,
                          let owner = self.lease.owner,
                          notification.userInfo?["generation"] as? String == owner.generation.uuidString,
                          let requester = notification.userInfo?["requester"] as? String,
                          requester != owner.bundleIdentifier,
                          [IntentBuildChannel.launch.bundleIdentifier,
                           IntentBuildChannel.development.bundleIdentifier].contains(requester),
                          !owner.activeSession, let model = self.model,
                          model.canYieldEngine, IntentRuntime.shared.canYieldEngine else { return }
                    NSApp.terminate(nil)
                }
            }
    }

    func release() {
        sessionObserver = nil
        if let switchObserver { DistributedNotificationCenter.default().removeObserver(switchObserver) }
        switchObserver = nil
        lease.release()
        acquired = false
    }

    private func explainBusy(_ owner: IntentEngineOwner?) {
        let alert = NSAlert()
        alert.messageText = "\(owner?.appName ?? "The other Intent app") is still in use"
        alert.informativeText = "Intent and Test Intent use separate workspaces. Only one can control your apps at a time. Finish its intention or close its selection screen, then open \(IntentBuildChannel.current.appName)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func explain(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not start \(IntentBuildChannel.current.appName)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
