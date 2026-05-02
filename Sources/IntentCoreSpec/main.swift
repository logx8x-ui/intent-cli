import Foundation
import IntentCore

struct SpecFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SpecFailure(description: message)
    }
}

do {
    try expect(IntentMenu.routeRootInput("s") == .shallow, "s should route to shallow")
    try expect(IntentMenu.routeRootInput("S") == .shallow, "S should route to shallow")
    try expect(IntentMenu.routeRootInput("d") == .deep, "d should route to deep")
    try expect(IntentMenu.routeRootInput("D") == .deep, "D should route to deep")

    var menu = IntentMenu()
    try expect(menu.screen == .root, "menu should start at root")
    try expect(menu.handle("s") == .showShallow, "s should show shallow")
    try expect(menu.screen == .shallow, "menu should enter shallow")
    try expect(menu.handle("\u{1B}") == .showRoot, "escape should return to root")
    try expect(menu.screen == .root, "escape should set root")
    try expect(menu.handle("s") == .showShallow, "s should show shallow again")
    try expect(menu.handle("b") == .showRoot, "b should return to root")
    try expect(menu.screen == .root, "b should set root")

    _ = menu.handle("s")
    try expect(menu.handle("1") == .start(.shallow(.imessages)), "1 should start Imessages")
    try expect(menu.handle("2") == .start(.shallow(.instagramReplies)), "2 should start Instagram replies")
    try expect(menu.handle("3") == .start(.shallow(.emails)), "3 should start Emails")

    _ = menu.handle("\u{1B}")
    _ = menu.handle("d")
    try expect(menu.handle("1") == .start(.deep(.dataScience)), "deep 1 should start Data Science")

    try expect(IntentCompleter.complete("i", in: ShallowTask.allCases) == nil, "ambiguous i should not complete")
    try expect(IntentCompleter.complete("ime", in: ShallowTask.allCases) == "imessages", "ime should complete")
    try expect(IntentCompleter.complete("im-", in: ShallowTask.allCases) == "imessages", "im- should complete")
    try expect(IntentCompleter.complete("insta", in: ShallowTask.allCases) == "instagram replies", "insta should complete")
    try expect(IntentCompleter.complete("em", in: ShallowTask.allCases) == "emails", "em should complete")
    try expect(IntentCompleter.complete("data", in: DeepTask.allCases) == "data science", "data should complete")
    try expect(IntentCompleter.complete("x", in: ShallowTask.allCases) == nil, "x should not complete")

    print("IntentCoreSpec passed")
} catch {
    fputs("IntentCoreSpec failed: \(error)\n", stderr)
    exit(1)
}
