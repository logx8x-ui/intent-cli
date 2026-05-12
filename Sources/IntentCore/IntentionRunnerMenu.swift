import Foundation

public struct IntentionRunnerMenu {
    public struct FolderOption: Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let intentions: [Intention]
    }

    public enum Screen: Equatable {
        case folders
        case intentions(String)
    }

    public enum Action: Equatable {
        case none
        case showFolders
        case showIntentions(String)
        case start(String)
    }

    public private(set) var screen: Screen = .folders
    public let folderOptions: [FolderOption]

    public init(intentions: [Intention]) {
        let grouped = Dictionary(grouping: intentions, by: \.folder)
        let orderedFolderNames = grouped.keys.sorted { left, right in
            let preferred = ["Deep", "Shallow", "Spot"]
            let leftIndex = preferred.firstIndex(of: left) ?? Int.max
            let rightIndex = preferred.firstIndex(of: right) ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }

        folderOptions = orderedFolderNames.map { folder in
            FolderOption(
                name: folder,
                intentions: (grouped[folder] ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    public var intentionOptions: [Intention] {
        guard case .intentions(let folder) = screen else { return [] }
        return folderOptions.first { $0.name == folder }?.intentions ?? []
    }

    @discardableResult
    public mutating func handle(_ rawInput: String) -> Action {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if input == "\u{1B}" || input == "b" {
            screen = .folders
            return .showFolders
        }

        guard let number = Int(input), number > 0 else {
            return .none
        }

        switch screen {
        case .folders:
            let index = number - 1
            guard folderOptions.indices.contains(index) else { return .none }
            let folder = folderOptions[index].name
            screen = .intentions(folder)
            return .showIntentions(folder)

        case .intentions:
            let index = number - 1
            guard intentionOptions.indices.contains(index) else { return .none }
            return .start(intentionOptions[index].id)
        }
    }
}
