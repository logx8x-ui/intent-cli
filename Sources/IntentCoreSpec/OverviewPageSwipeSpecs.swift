import Foundation
import IntentCore

func runOverviewPageSwipeSpecs() throws {
    func contacts(_ count: Int = 2, x: Double, y: Double = 0.5) -> [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, CGPoint(x: x, y: y + Double($0) * 0.01)) })
    }
    var gesture = OverviewPageSwipe()
    _ = gesture.update(contacts: contacts(x: 0.7))
    try expect(gesture.update(contacts: contacts(x: 0.45)) == .right, "Negative two-contact translation navigates back toward apps")
    try expect(gesture.update(contacts: contacts(x: 0.2)) == nil, "One gesture changes one page")
    _ = gesture.update(contacts: [:])
    _ = gesture.update(contacts: contacts(x: 0.3))
    try expect(gesture.update(contacts: contacts(x: 0.55)) == .left, "Positive two-contact translation opens the task side after direction reversal")
    gesture.reset(); _ = gesture.update(contacts: contacts(3, x: 0.7))
    try expect(gesture.update(contacts: contacts(3, x: 0.45)) == .right, "Negative three-contact translation uses the same reversed direction")
    try expect(gesture.update(contacts: contacts(2, x: 0.2)) == nil, "Lifting one finger after navigation cannot navigate again")
    gesture.reset(); _ = gesture.update(contacts: contacts(3, x: 0.3))
    try expect(gesture.update(contacts: contacts(3, x: 0.55)) == .left, "Positive three-contact translation opens the task side too")
    gesture.reset(); _ = gesture.update(contacts: contacts(1, x: 0.7))
    _ = gesture.update(contacts: contacts(2, x: 0.7))
    _ = gesture.update(contacts: contacts(3, x: 0.69))
    try expect(gesture.update(contacts: contacts(3, x: 0.45)) == .right, "Successively landing fingers retain the reversed page direction")
    gesture.reset(); _ = gesture.update(contacts: contacts(2, x: 0.7))
    _ = gesture.update(contacts: contacts(2, x: 0.6))
    _ = gesture.update(contacts: contacts(3, x: 0.6))
    try expect(gesture.update(contacts: contacts(3, x: 0.3)) == nil, "Adding a finger to a moving scroll cannot restart navigation")
    for count in [1, 4, 5] {
        gesture.reset()
        _ = gesture.update(contacts: contacts(count, x: 0.7))
        try expect(gesture.update(contacts: contacts(count, x: 0.2)) == nil, "Other finger counts do not switch pages")
    }
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.7))
    _ = gesture.update(contacts: contacts(x: 0.7, y: 0.8))
    try expect(gesture.update(contacts: contacts(x: 0.2, y: 0.8)) == nil, "Vertical gesture cannot turn into page navigation")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.7))
    _ = gesture.update(contacts: contacts(4, x: 0.65))
    try expect(gesture.update(contacts: contacts(x: 0.2)) == nil, "Fourth finger disqualifies current gesture")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.7))
    _ = gesture.update(contacts: [:], cancelled: true)
    try expect(gesture.update(contacts: contacts(x: 0.2)) == nil, "Cancelled gesture cannot navigate")
    _ = gesture.update(contacts: [:]); _ = gesture.update(contacts: contacts(x: 0.7))
    var replaced = contacts(x: 0.2); replaced[9] = replaced.removeValue(forKey: 1)
    try expect(gesture.update(contacts: replaced) == nil, "Replacement contact cannot inherit old movement")
    gesture.reset(); _ = gesture.update(contacts: contacts(x: 0.7))
    var oneMoving = contacts(x: 0.7); oneMoving[0] = CGPoint(x: 0.0, y: 0.5)
    try expect(gesture.update(contacts: oneMoving) == nil, "Two touches with only one moving are not a swipe")
}
