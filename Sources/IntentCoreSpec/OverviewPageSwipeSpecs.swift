import Foundation
import IntentCore

func runOverviewPageSwipeSpecs() throws {
    func contacts(_ count: Int = 2, x: Double, y: Double = 0.5) -> [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, CGPoint(x: x, y: y + Double($0) * 0.01)) })
    }
    var gesture = OverviewPageSwipe()
    _ = gesture.update(contacts: contacts(x: 0.3))
    try expect(gesture.update(contacts: contacts(x: 0.4)) == nil && gesture.progress > 0,
        "Two fingers continuously move the page before navigation commits")
    _ = gesture.update(contacts: contacts(x: 0.55))
    try expect(gesture.update(contacts: [:]) == .left && gesture.progress == 0,
        "Releasing a sufficient leftward page swipe opens Tasks once")
    try expect(gesture.update(contacts: [:]) == nil, "One gesture commits at most once")
    _ = gesture.update(contacts: contacts(x: 0.7)); _ = gesture.update(contacts: contacts(x: 0.45))
    try expect(gesture.update(contacts: [:]) == .right, "The reverse two-finger swipe returns to apps")
    for count in [1, 3, 4, 5] {
        gesture.reset(); _ = gesture.update(contacts: contacts(count, x: 0.3))
        _ = gesture.update(contacts: contacts(count, x: 0.7))
        try expect(gesture.progress == 0 && gesture.update(contacts: [:]) == nil,
            "Only exactly two fingers navigate; three-finger system gestures remain untouched")
    }
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    _ = gesture.update(contacts: contacts(x: 0.65)); _ = gesture.update(contacts: contacts(x: 0.34))
    try expect(gesture.update(contacts: [:]) == nil, "Reversing before release cancels navigation")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    _ = gesture.update(contacts: contacts(x: 0.65)); _ = gesture.update(contacts: [:], cancelled: true)
    try expect(gesture.progress == 0 && gesture.update(contacts: [:]) == nil, "Cancelled system gestures spring back without navigation")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    _ = gesture.update(contacts: contacts(x: 0.3, y: 0.8)); _ = gesture.update(contacts: contacts(x: 0.7, y: 0.8))
    try expect(gesture.update(contacts: [:]) == nil, "Vertical scrolling cannot become a page swipe")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    _ = gesture.update(contacts: contacts(3, x: 0.31)); _ = gesture.update(contacts: contacts(x: 0.7))
    try expect(gesture.update(contacts: [:]) == nil, "An added third finger cancels the whole sequence")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    var replaced = contacts(x: 0.65); replaced[9] = replaced.removeValue(forKey: 1)
    _ = gesture.update(contacts: replaced)
    try expect(gesture.update(contacts: [:]) == nil, "A replacement finger cannot inherit progress")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    var oneMoving = contacts(x: 0.3); oneMoving[0] = CGPoint(x: 0.9, y: 0.5)
    _ = gesture.update(contacts: oneMoving)
    try expect(gesture.update(contacts: [:]) == nil, "One moving finger is not a two-finger swipe")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.3))
    _ = gesture.update(contacts: contacts(x: 0.65)); _ = gesture.update(contacts: contacts(1, x: 0.65))
    try expect(gesture.update(contacts: [:]) == .left, "Sequential normal finger lifts preserve the release decision")
}
