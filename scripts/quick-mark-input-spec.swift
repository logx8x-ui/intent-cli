import Foundation

struct QuickMarkInputSpecFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw QuickMarkInputSpecFailure(description: message) }
}

@main
struct QuickMarkInputSpec {
    static func main() {
        do {
            try runQuickMarkKeyboardInputSpecs()
            try runQuickMarkExpiryTimerSpecs()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-run-diagnostic-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("quick-run-diagnostics.json")
            let diagnostics = QuickMarkRunDiagnostics(fileURL: url)
            diagnostics.record(.stagedRunQueued, route: .staged)
            diagnostics.record(.stagedRunDelivered, route: .staged)
            for _ in 0..<100 { diagnostics.record(.capsEventFiltered, route: .staged) }
            diagnostics.flushForChecks()
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(QuickMarkRunDiagnostics.Snapshot.self, from: data)
            try expect(snapshot.counts["staged.capsEventFiltered"] == 100 && snapshot.counts.count == 3,
                "Run diagnostics retain fixed semantic counters, not a growing input-event log")
            try expect(snapshot.lastDispatchPhase == .stagedRunDelivered && snapshot.latestPhase == .capsEventFiltered,
                "Caps releases/filtered notifications do not overwrite the last Run dispatch outcome")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try expect(data.count < 2_048 && files.count == 1,
                "Run diagnostics stay in one bounded latest-snapshot file")
            print("Privacy-safe Run diagnostics regressions passed (semantic counters and one bounded latest snapshot)")
        } catch {
            print("Native keyboard regression failed: \(error)")
            exit(1)
        }
    }
}
