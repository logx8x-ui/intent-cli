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
        } catch {
            print("Native keyboard regression failed: \(error)")
            exit(1)
        }
    }
}
