import Foundation

/// The session monitor's bounded confirmation phase. Delivery stays on the
/// owning actor so Finish/replacement cannot interleave with a stop decision.
@MainActor
public enum BrowserSelectedTabPresenceMonitor {
    public static func confirm(_ check: BrowserSelectedTabPresenceCheck?,
                               isCurrent: () -> Bool,
                               didConfirm: (BrowserSelectedTabPresenceCheck.Result) -> Void) async {
        @MainActor func deliver(_ result: BrowserSelectedTabPresenceCheck.Result) {
            guard !Task.isCancelled, isCurrent() else { return }
            didConfirm(result)
        }
        guard !Task.isCancelled, isCurrent() else { return }
        guard let check else { deliver(.changed); return }
        do { try check.request() } catch { deliver(.pending); return }
        for _ in 0..<55 {
            guard !Task.isCancelled, isCurrent() else { return }
            let result = check.poll()
            if result != .pending { deliver(result); return }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
        deliver(.pending)
    }
}
