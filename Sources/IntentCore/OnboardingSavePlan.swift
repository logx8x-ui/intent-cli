import Foundation

/// A deterministic save decision. Existing setups change only after the caller
/// passes explicit replacement intent; replay alone never authorizes overwrite.
public struct OnboardingSavePlan: Equatable {
    public enum Action: Equatable { case keepExisting, insert, replaceExisting }
    public let action: Action
    public let intention: Intention

    public init(candidate: Intention, latestPurpose: String?, existing: Intention?,
                replaceExisting: Bool, insertionPosition: GraphPoint) {
        if let existing, !replaceExisting {
            action = .keepExisting; intention = existing
            return
        }
        var prepared = candidate
        if let purpose = latestPurpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty {
            prepared.name = purpose
        }
        let position = existing?.graphPosition ?? insertionPosition
        if let existing {
            prepared.id = existing.id
            prepared.folder = existing.folder
        }
        if prepared.selectionOnly {
            prepared.restrictionNodes.removeAll { $0.id == QuickSelection.startupSuppressionID }
        }
        let dx = position.x - prepared.graphPosition.x
        let dy = position.y - prepared.graphPosition.y
        prepared.graphPosition = position
        prepared.restrictionNodes = prepared.restrictionNodes.map { node in
            var moved = node
            moved.position = .init(x: node.position.x + dx, y: node.position.y + dy)
            return moved
        }
        prepared.frictionNodes = prepared.frictionNodes.map { node in
            var moved = node
            moved.position = .init(x: node.position.x + dx, y: node.position.y + dy)
            return moved
        }
        action = existing == nil ? .insert : .replaceExisting
        intention = prepared
    }
}
