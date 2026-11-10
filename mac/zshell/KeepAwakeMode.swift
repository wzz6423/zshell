import Foundation

enum KeepAwakeMode: String, CaseIterable {
    case off
    case whileRunning = "on"
    case whileAgentsWork = "agents"

    init(persisted value: String?) {
        self = value.flatMap(Self.init(rawValue:)) ?? .off
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .whileRunning: String(localized: "While Zshell is running")
        case .whileAgentsWork: String(localized: "While local agents work")
        }
    }
}
