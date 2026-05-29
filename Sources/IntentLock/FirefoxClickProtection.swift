import CoreGraphics

public struct FirefoxWindowBounds: Equatable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: CGFloat { x + width }
    public var maxY: CGFloat { y + height }
}

public enum FirefoxClickProtection {
    private static let topChromeHeight: CGFloat = 105
    private static let sideberyTabListWidth: CGFloat = 470

    public static func isProtected(
        point: CGPoint,
        windowBounds bounds: FirefoxWindowBounds,
        protectTopChrome: Bool = true
    ) -> Bool {
        false
    }
}
