import Foundation

/// Bounded, semantic diagnostics only. No key codes, flags, characters, app or
/// tab identity enter this API. File work runs outside the native input tap.
final class QuickMarkRunDiagnostics: @unchecked Sendable {
    enum Phase: String, Codable {
        case capsEventFiltered, capsChordPassedThrough, overviewConsumed
        case stagedRunQueued, stagedRunDelivered, stagedRunCanceled
    }
    enum Route: String, Codable { case overview, staged }
    struct Snapshot: Codable {
        let updatedAt: Date
        let latestPhase: Phase
        let latestRoute: Route
        let counts: [String: Int]
        let lastDispatchAt: Date?
        let lastDispatchPhase: Phase?
    }
    private let fileURL: URL
    private let queue = DispatchQueue(label: "intent.quick-run-diagnostics", qos: .utility)
    private var counts: [String: Int] = [:]
    private var lastDispatchAt: Date?
    private var lastDispatchPhase: Phase?
    init(fileURL: URL) { self.fileURL = fileURL }

    func record(_ phase: Phase, route: Route) {
        queue.async { [self] in
            let now = Date()
            counts["\(route.rawValue).\(phase.rawValue)", default: 0] += 1
            if phase == .overviewConsumed || phase == .stagedRunDelivered || phase == .stagedRunCanceled {
                lastDispatchAt = now; lastDispatchPhase = phase
            }
            let snapshot = Snapshot(updatedAt: now, latestPhase: phase, latestRoute: route,
                counts: counts, lastDispatchAt: lastDispatchAt, lastDispatchPhase: lastDispatchPhase)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Isolated fixture barrier; never called by production input callbacks.
    func flushForChecks() { queue.sync {} }
}
