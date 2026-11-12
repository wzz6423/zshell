import Foundation

enum NewSessionDirectoryPolicy: String, CaseIterable {
    case current
    case project
    case home
    case custom

    init(persisted value: String?) {
        self = value.flatMap(Self.init(rawValue:)) ?? .current
    }

    var title: String {
        switch self {
        case .current: String(localized: "Current directory")
        case .project: String(localized: "Project directory")
        case .home: String(localized: "Home directory")
        case .custom: String(localized: "Custom directory")
        }
    }
}

enum TerminalSessionDirectory {
    struct Context {
        var currentDirectory: String?
        var projectDirectory: String?
    }

    enum ConfigurationError: Error, Equatable {
        case invalidPath
        case missingDirectory
        case notDirectory
        case inaccessibleDirectory
    }

    static func customDirectory(
        _ rawInput: String, homeDirectory: String = NSHomeDirectory()
    ) -> Result<String, ConfigurationError> {
        let input = rawInput.hasPrefix("/") || rawInput == "~" || rawInput.hasPrefix("~/")
            ? rawInput : rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if input == "~" {
            path = homeDirectory
        } else if input.hasPrefix("~/") {
            path = (homeDirectory as NSString).appendingPathComponent(String(input.dropFirst(2)))
        } else {
            path = input
        }
        return validateDirectory(path)
    }

    private static func validateDirectory(_ path: String) -> Result<String, ConfigurationError> {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .failure(.invalidPath) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure(.missingDirectory)
        }
        guard isDirectory.boolValue else { return .failure(.notDirectory) }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(.inaccessibleDirectory)
        }
        return .success(path)
    }

    static func validatedOrHome(_ directory: String?, homeDirectory: String = NSHomeDirectory()) -> String {
        guard let directory, directory.hasPrefix("/"),
              case .success(let path) = validateDirectory(directory)
        else { return homeDirectory }
        return path
    }

    static func resolve(
        explicitDirectory: String? = nil,
        pinnedDirectory: String? = nil,
        groupDirectory: String? = nil,
        context: Context = .init(),
        policy: NewSessionDirectoryPolicy,
        customDirectory: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        // An unavailable explicit location must never redirect a template,
        // restored terminal, or pinned project into an unrelated global folder.
        if let directory = explicitDirectory ?? pinnedDirectory ?? groupDirectory {
            return validatedOrHome(directory, homeDirectory: homeDirectory)
        }
        let current = validatedOrHome(context.currentDirectory, homeDirectory: homeDirectory)
        switch policy {
        case .current: return current
        case .project:
            return validatedOrHome(context.projectDirectory ?? context.currentDirectory, homeDirectory: homeDirectory)
        case .home: return homeDirectory
        case .custom:
            guard case .success(let directory) = self.customDirectory(customDirectory, homeDirectory: homeDirectory) else {
                return current
            }
            return directory
        }
    }
}
