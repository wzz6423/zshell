import Foundation

nonisolated struct RemoteFileSource: Equatable, Sendable {
    let endpoint: SSHEndpoint
    let root: String
    var authentication: SSHAuthentication = .agent
    var credentialID: UUID?
}

nonisolated enum FileSource {
    case local
    case remote(RemoteFileSource)
}

nonisolated struct RemoteFileCapabilities: Equatable, Sendable {
    let create: Bool
    let rename: Bool
    let trash: Bool
    let save: Bool
    static let unavailable = Self(create: false, rename: false, trash: false, save: false)
}

nonisolated struct RemoteTrashEntry: Sendable {}

nonisolated struct RemoteFileService {
    func capabilities(source: RemoteFileSource) throws -> RemoteFileCapabilities { .unavailable }
    func create(source: RemoteFileSource, directory: String, name: String, isDirectory: Bool) throws -> String { throw CocoaError(.fileWriteUnknown) }
    func rename(source: RemoteFileSource, path: String, name: String) throws -> String { throw CocoaError(.fileWriteUnknown) }
    func trash(source: RemoteFileSource, path: String) throws -> RemoteTrashEntry { throw CocoaError(.fileWriteUnknown) }
    func restore(source: RemoteFileSource, entry: RemoteTrashEntry) throws -> String { throw CocoaError(.fileWriteUnknown) }
}
