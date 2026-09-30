import Foundation

/// A useful title even when the user chooses to start without naming their work.
public enum SessionNaming {
    public static func summary(apps: [AllowedApp], tabCounts: [String: Int] = [:]) -> String {
        var seen = Set<String>()
        let parts = apps.filter { seen.insert($0.bundleIdentifier).inserted }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { app in
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let count = tabCounts[app.bundleIdentifier], count > 0 else { return name }
            return name + "(\(count) \(count == 1 ? "tab" : "tabs"))"
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? "intention" : parts.joined(separator: "-")
    }
    public static func rename(_ intention: Intention, to name: String) -> Intention {
        var result = intention
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.nameIsAutomatic = trimmed.isEmpty
        result.name = trimmed.isEmpty ? (intention.automaticName ?? summary(apps: intention.allowedApps.filter {
            !intention.presetAllowedBundleIdentifiers.contains($0.bundleIdentifier)
        })) : trimmed
        return result
    }
}

/// Keep persisted order stable through deletions, imports and duplicate legacy IDs.
public enum SavedSlotOrder {
    public static func normalized(_ order: [String], available: [String]) -> [String] {
        let live = Set(available); var seen = Set<String>()
        return (order + available).filter { live.contains($0) && seen.insert($0).inserted }
    }
    public static func swapping(_ source: String, with target: String, order: [String], available: [String]) -> [String] {
        var ids = normalized(order, available: available)
        if let a = ids.firstIndex(of: source), let b = ids.firstIndex(of: target) { ids.swapAt(a, b) }
        return ids
    }
}
