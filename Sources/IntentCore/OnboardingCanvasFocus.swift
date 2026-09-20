import Foundation

/// Frames the saved setup and its connected modifiers without moving any nodes.
/// Insets leave the dashboard's header and bottom controls unobstructed.
public struct OnboardingCanvasFocus {
    public let scale: Double
    public let offset: GraphPoint

    public init(intention: Intention, viewportWidth: Double, viewportHeight: Double) {
        // These bounds match the fixed card sizes rendered by GraphNodeViews.
        var bounds = CGRect(x: intention.graphPosition.x - 100, y: intention.graphPosition.y - 95,
                            width: 200, height: 190)
        for node in intention.restrictionNodes {
            bounds = bounds.union(CGRect(x: node.position.x - 58, y: node.position.y - 58, width: 116, height: 116))
        }
        for node in intention.frictionNodes {
            bounds = bounds.union(CGRect(x: node.position.x - 63, y: node.position.y - 56, width: 126, height: 112))
        }
        bounds = bounds.insetBy(dx: -16, dy: -16)
        let availableWidth = max(1, viewportWidth - 80)
        let availableHeight = max(1, viewportHeight - 172)
        scale = min(1, availableWidth / Double(bounds.width), availableHeight / Double(bounds.height))
        offset = .init(x: -Double(bounds.midX) * scale, y: -14 - Double(bounds.midY) * scale)
    }
}
