import Foundation
import IntentCore

func readMessage() -> Data? {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    let lengthRead = FileHandle.standardInput.readData(ofLength: 4)
    guard lengthRead.count == 4 else { return nil }
    lengthRead.copyBytes(to: &lengthBytes, count: 4)

    let length = UInt32(lengthBytes[0])
        | UInt32(lengthBytes[1]) << 8
        | UInt32(lengthBytes[2]) << 16
        | UInt32(lengthBytes[3]) << 24

    return FileHandle.standardInput.readData(ofLength: Int(length))
}

func writeMessage<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
}

struct HostResponse: Codable {
    var active: Bool
    var allowedWebsites: [String]
    var blockTabSwitching: Bool
    var blockNavigation: Bool
    var blockNewTabs: Bool
    var allowGoogleSearchTabs: Bool
}

_ = readMessage()

let fileURL = ActiveBrowserRulesStore.defaultFileURL()
let response: HostResponse

if let data = try? Data(contentsOf: fileURL),
   let rules = try? JSONDecoder().decode(ActiveBrowserRules.self, from: data) {
    response = HostResponse(
        active: rules.active,
        allowedWebsites: rules.allowedWebsites,
        blockTabSwitching: rules.blockTabSwitching,
        blockNavigation: rules.blockNavigation,
        blockNewTabs: rules.blockNewTabs,
        allowGoogleSearchTabs: rules.allowGoogleSearchTabs
    )
} else {
    response = HostResponse(active: false, allowedWebsites: [], blockTabSwitching: false, blockNavigation: false, blockNewTabs: false, allowGoogleSearchTabs: false)
}

try writeMessage(response)
