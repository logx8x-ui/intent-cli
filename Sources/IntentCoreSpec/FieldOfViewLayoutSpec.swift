import Foundation
import IntentCore

/// The thumbnail and its label are one occupied region, even for very small windows.
private func overviewFootprint(_ frame: CGRect, tabHeight: CGFloat) -> CGRect {
    let width = max(FieldOfViewLayout.minimumCaptionWidth, frame.width)
    return CGRect(x: frame.midX - width / 2 - 2, y: frame.minY - tabHeight,
                  width: width + 4, height: frame.height + tabHeight + FieldOfViewLayout.captionHeight)
}

private func checkOverview(sizes: [CGSize], bounds: CGRect, tabHeight: CGFloat = 0, sourceFrames: [CGRect]? = nil) throws {
    func makeFrames() -> [CGRect] {
        if let sourceFrames { return FieldOfViewLayout.frames(sourceFrames: sourceFrames, in: bounds, tabHeight: tabHeight) }
        return FieldOfViewLayout.frames(sizes: sizes, in: bounds, tabHeight: tabHeight)
    }
    let frames = makeFrames()
    try expect(frames.count == sizes.count, "Every window receives a thumbnail, including crowded desktops")
    try expect(frames == makeFrames(),
               "The same desktop has a deterministic arrangement")
    let scale = frames[0].width / sizes[0].width
    try expect(scale > 0 && scale <= 1, "Overview previews have a positive scale and never exceed native window size")
    for (index, frame) in frames.enumerated() {
        try expect(abs(frame.width / frame.height - sizes[index].width / sizes[index].height) < 0.0001,
                   "Portrait, landscape and tiny windows keep their aspect ratio")
        try expect(abs(frame.width / sizes[index].width - scale) < 0.0001,
                   "A small source window remains smaller than a large source window")
        let footprint = overviewFootprint(frame, tabHeight: tabHeight)
        try expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(footprint),
                   "The preview, outline, caption and tab decoration all stay on-screen (\(sizes.count): \(footprint))")
        for other in frames.dropFirst(index + 1) {
            try expect(!footprint.intersects(overviewFootprint(other, tabHeight: tabHeight)),
                       "Captions on narrow previews must not collide with neighbouring windows")
        }
    }
}

func runFieldOfViewLayoutSpecs() throws {
    let displays = [
        CGRect(x: 32, y: 98, width: 1300, height: 620),
        CGRect(x: 20, y: 40, width: 850, height: 1250),
        CGRect(x: -2580, y: -250, width: 2540, height: 680)
    ]
    for count in 1...50 {
        let mixed = (0..<count).map { index -> CGSize in
            switch index % 4 {
            case 0: return CGSize(width: 1400, height: 850)
            case 1: return CGSize(width: 600, height: 1000)
            case 2: return CGSize(width: 280, height: 180)
            default: return CGSize(width: 900, height: 520)
            }
        }
        for bounds in displays { try checkOverview(sizes: mixed, bounds: bounds) }
    }
    // Opening the tab sidebar narrows the same overview. Source geometry must
    // keep the remaining preview/caption regions inside that smaller surface.
    for count in [2, 21, 50] {
        let sources: [CGRect] = (0..<count).map { index in
            let x = CGFloat((index % 5) * 240 - 1200)
            let y = CGFloat((index / 5) * 100)
            let width: CGFloat = index % 3 == 0 ? 500 : 1400
            let height: CGFloat = index % 3 == 0 ? 800 : 850
            return CGRect(x: x, y: y, width: width, height: height)
        }
        try checkOverview(sizes: sources.map(\.size), bounds: CGRect(x: 18, y: 30, width: 880, height: 790), sourceFrames: sources)
    }
    // The legacy tab-space API remains bounded while the current picker reserves
    // only captions; none of the native browser-matching behavior is involved.
    for count in [1, 2, 9, 16, 30, 50] {
        try checkOverview(sizes: (0..<count).map { _ in CGSize(width: 1400, height: 850) },
                          bounds: displays[0], tabHeight: 62)
    }
    try checkOverview(sizes: [CGSize(width: 45, height: 28), CGSize(width: 180, height: 90), CGSize(width: 40, height: 180)], bounds: displays[0])

    // Mirrors the reported desktop's mix of Finder windows, full-size browsers,
    // utilities and three apps without a visible window. The previous equal-cell
    // layout could only reach 0.1703 here, leaving most of the display unused.
    let crowded: [CGSize] = [
        .init(width: 600, height: 560), .init(width: 650, height: 500), .init(width: 780, height: 460),
        .init(width: 780, height: 370), .init(width: 780, height: 370), .init(width: 780, height: 370),
        .init(width: 780, height: 370), .init(width: 780, height: 370), .init(width: 1240, height: 770),
        .init(width: 1450, height: 910), .init(width: 1230, height: 820), .init(width: 1450, height: 910),
        .init(width: 1450, height: 910), .init(width: 1450, height: 910), .init(width: 1450, height: 910),
        .init(width: 470, height: 520), .init(width: 600, height: 450), .init(width: 200, height: 360),
        .init(width: 360, height: 240), .init(width: 360, height: 240), .init(width: 360, height: 240)
    ]
    let crowdedBounds = CGRect(x: 32, y: 50, width: 1604, height: 790)
    try checkOverview(sizes: crowded, bounds: crowdedBounds)
    let packed = FieldOfViewLayout.frames(sizes: crowded, in: crowdedBounds, tabHeight: 0)
    try expect(packed[0].width / crowded[0].width >= 0.24,
               "The reported crowded desktop must use substantially larger previews than the sparse equal-cell grid")

    let spatial = [
        CGRect(x: 1000, y: 800, width: 600, height: 400), // bottom right
        CGRect(x: 0, y: 0, width: 600, height: 400), // top left
        CGRect(x: 1000, y: 0, width: 600, height: 400), // top right
        CGRect(x: 0, y: 800, width: 600, height: 400) // bottom left
    ]
    let positioned = FieldOfViewLayout.frames(sourceFrames: spatial, in: CGRect(x: 20, y: 20, width: 1400, height: 1000), tabHeight: 0)
    try expect(positioned.count == 4 && positioned == FieldOfViewLayout.frames(sourceFrames: spatial, in: CGRect(x: 20, y: 20, width: 1400, height: 1000), tabHeight: 0),
               "Source-position packing stays deterministic and returns original window indices")
    try expect(positioned[1].midX < positioned[2].midX && positioned[3].midX < positioned[0].midX
               && positioned[1].midY < positioned[3].midY && positioned[2].midY < positioned[0].midY,
               "Windows retain their familiar left/right and upper/lower arrangement when it fits")

    let spatialBounds = CGRect(x: 20, y: 20, width: 1400, height: 1000)
    try expect(FieldOfViewLayout.frames(sourceFrames: spatial.map { $0.offsetBy(dx: -2400, dy: 700) }, in: spatialBounds, tabHeight: 0) == positioned,
               "A different monitor origin does not scramble the same spatial arrangement")
    try expect(Array(FieldOfViewLayout.frames(sourceFrames: spatial.reversed(), in: spatialBounds, tabHeight: 0).reversed()) == positioned,
               "Changing window enumeration order does not scramble a familiar four-corner layout")

    try expect(FieldOfViewLayout.frames(sizes: [], in: displays[0]).isEmpty, "An empty desktop needs no layout")
    try expect(FieldOfViewLayout.frames(sizes: crowded, in: .zero).isEmpty, "An unavailable display does not produce invalid frames")
    try expect(FieldOfViewLayout.frames(sizes: crowded, in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800)).isEmpty,
               "Nonfinite display geometry is rejected")
    print("FieldOfViewLayout specs passed (1–50 windows, compact packing, spatial order and caption bounds)")
}
