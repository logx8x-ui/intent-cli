import Foundation
import IntentCore
import CoreGraphics

struct SpecFailure: Error { let description: String }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw SpecFailure(description: message) }
}
@main struct DesktopSessionSpecs {
    static func main() throws {
        try runDesktopSessionCoverageSpecs()
        let onConsole = kCGSessionOnConsoleKey as String
        try expect(DesktopSessionAvailability.classify(nil) == .unknown, "Missing Quartz session is unknown")
        try expect(DesktopSessionAvailability.classify([onConsole: kCFBooleanFalse!]) == .secured, "Off-console is positive protection")
        try expect(DesktopSessionAvailability.classify(["CGSSessionScreenIsLocked": kCFBooleanTrue!]) == .secured, "Positive lock is protection")
        try expect(DesktopSessionAvailability.classify([onConsole: kCFBooleanTrue!]) == .unknown, "Absent lock field is unknown, never secured")
        try expect(DesktopSessionAvailability.classify([onConsole: kCFBooleanTrue!, "CGSSessionScreenIsLocked": kCFBooleanFalse!]) == .available, "Positive available state")
        for value: Any in [1, 0, "true", "false", NSNumber(value: 1), NSNumber(value: 0)] {
            try expect(DesktopSessionAvailability.classify([onConsole: kCFBooleanTrue!, "CGSSessionScreenIsLocked": value]) == .unknown,
                "Numeric/string lock values cannot confer a suspension")
        }
        print("PASS secure-desktop production coverage gate, all four pending policies, stale callbacks, stop, unknown, strict native classifier")
    }
}
