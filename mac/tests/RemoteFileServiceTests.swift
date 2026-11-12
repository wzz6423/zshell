import Darwin
import Foundation

private var checks = 0

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    guard try condition() else { throw NSError(domain: "RemoteFileTests", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func rejects(_ expected: RemoteFileService.Failure, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch let actual as RemoteFileService.Failure {
        try require(actual == expected, "Expected \(expected), received \(actual)")
        return
    }
    throw NSError(domain: "RemoteFileTests", code: 0, userInfo: [NSLocalizedDescriptionKey: "Expected \(expected)"])
}

@main struct RemoteFileServiceTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let temporary = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = temporary.appendingPathComponent("remote '项目 with spaces")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let service = RemoteFileService(transport: OpenSSHTransport(executableURL: URL(fileURLWithPath: CommandLine.arguments[2]), timeout: 10, outputLimit: 8 << 20))
        let source = RemoteFileSource(endpoint: try SSHEndpoint(host: "fixture.invalid"), root: root.path)
        let capabilities = try service.capabilities(source: source)
        try require(capabilities.create && capabilities.rename && capabilities.trash && capabilities.save, "macOS has safe existing tools")
        let original = try service.create(source: source, directory: root.path, name: "draft '中文.txt", isDirectory: false)
        let empty = try service.read(source: source, path: original)
        try require(empty.text == "" && empty.isRegular, "New file reads through the production process path")
        guard case .saved(let first) = try service.save(source: source, path: original, text: "first\n", baseline: empty) else { fatalError("Initial save conflicted") }
        try require(first.text == "first\n", "Saved snapshot contains exact bytes")
        try Data("agent\n".utf8).write(to: URL(fileURLWithPath: original))
        guard case .conflict(let changed) = try service.save(source: source, path: original, text: "draft\n", baseline: first) else { fatalError("External edits were not detected") }
        try require(changed.text == "agent\n", "Conflict reports the remote contents")
        try require(try String(contentsOfFile: original, encoding: .utf8) == "agent\n", "Conflict preserves external contents")
        try Data("newer agent\n".utf8).write(to: URL(fileURLWithPath: original))
        guard case .conflict(let newest) = try service.save(source: source, path: original, text: "draft\n", baseline: first, overwrite: changed) else { fatalError("Stale overwrite approval was accepted") }
        guard case .saved = try service.save(source: source, path: original, text: "draft\n", baseline: first, overwrite: newest) else { fatalError("Compared version could not be saved") }
        try require(try String(contentsOfFile: original, encoding: .utf8) == "draft\n", "Explicit overwrite saves the compared version")

        let collision = try service.create(source: source, directory: root.path, name: "occupied.txt", isDirectory: false)
        try Data("preserve".utf8).write(to: URL(fileURLWithPath: collision))
        try rejects(.collision) { _ = try service.rename(source: source, path: original, name: "occupied.txt") }
        try rejects(.collision) { _ = try service.create(source: source, directory: root.path, name: "occupied.txt", isDirectory: false) }
        try require(try String(contentsOfFile: collision, encoding: .utf8) == "preserve", "No-clobber operations preserve collisions")
        let renamed = try service.rename(source: source, path: original, name: "RENAMED.txt")
        let caseRenamed = try service.rename(source: source, path: renamed, name: "renamed.txt")
        try require(fm.fileExists(atPath: caseRenamed), "Case-only rename is supported without bypassing collisions")
        let trash = try service.trash(source: source, path: caseRenamed)
        try require(!fm.fileExists(atPath: caseRenamed), "Remote trash removes the original directory entry")
        try require(fm.fileExists(atPath: root.appendingPathComponent(".zshell-trash/" + trash.path).path), "Remote trash retains recoverable contents")
        _ = try service.create(source: source, directory: root.path, name: "renamed.txt", isDirectory: false)
        try rejects(.collision) { _ = try service.restore(source: source, entry: trash) }
        try fm.removeItem(atPath: caseRenamed)
        _ = try service.restore(source: source, entry: trash)
        try require(try String(contentsOfFile: caseRenamed, encoding: .utf8) == "draft\n", "Restore keeps the original bytes")

        let outside = temporary.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkSnapshot = try service.read(source: source, path: link.path)
        try require(!linkSnapshot.isRegular && linkSnapshot.data == nil, "Symbolic-link bytes are never read")
        try rejects(.unsafePath) { _ = try service.save(source: source, path: link.path, text: "unsafe", baseline: linkSnapshot) }
        try rejects(.unsafePath) { _ = try service.rename(source: source, path: link.path, name: "moved-link") }
        try rejects(.unsafePath) { _ = try service.trash(source: source, path: link.path) }
        let escaped = root.appendingPathComponent("escaped")
        try fm.createSymbolicLink(at: escaped, withDestinationURL: temporary)
        try rejects(.unsafePath) { _ = try service.create(source: source, directory: escaped.path, name: "intrusion", isDirectory: false) }
        try rejects(.unsafePath) { _ = try service.read(source: source, path: root.path + "/../outside.txt") }
        try rejects(.unsafePath) { _ = try service.create(source: source, directory: root.path, name: "../intrusion", isDirectory: false) }
        try require(try String(contentsOf: outside, encoding: .utf8) == "outside", "Escapes never modify the outside file")

        let folder = try service.create(source: source, directory: root.path, name: "folder", isDirectory: true)
        _ = try service.create(source: source, directory: folder, name: "child", isDirectory: false)
        let folderTrash = try service.trash(source: source, path: folder)
        _ = try service.restore(source: source, entry: folderTrash)
        try require(fm.fileExists(atPath: folder + "/child"), "Directory trash and restore keep descendants")
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: RemoteFileService.maximumBytes + 1).write(to: large)
        let largeSnapshot = try service.read(source: source, path: large.path)
        try require(largeSnapshot.data == nil, "Oversized files do not cross the transport")
        try rejects(.tooLarge) { _ = try service.save(source: source, path: large.path, text: String(repeating: "x", count: RemoteFileService.maximumBytes + 1), baseline: largeSnapshot) }
        try Data(repeating: 65, count: RemoteFileService.maximumBytes).write(to: large)
        let maximumSnapshot = try service.read(source: source, path: large.path)
        guard case .saved(let maximumSaved) = try service.save(source: source, path: large.path,
            text: String(repeating: "B", count: RemoteFileService.maximumBytes), baseline: maximumSnapshot) else { fatalError("Maximum-size save conflicted") }
        try require(maximumSaved.data?.count == RemoteFileService.maximumBytes, "A 5 MiB baseline and draft both fit the bounded protocol")
        let bom = root.appendingPathComponent("bom.txt")
        try Data([0xef, 0xbb, 0xbf, 65]).write(to: bom)
        let bomSnapshot = try service.read(source: source, path: bom.path)
        _ = try service.save(source: source, path: bom.path, text: "B", baseline: bomSnapshot)
        try require(try Data(contentsOf: bom) == Data([0xef, 0xbb, 0xbf, 66]), "UTF-8 BOM survives editing")

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try service.create(source: source, directory: root.path, name: "raced.txt", isDirectory: false); return true }
                    catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        try require(results.filter { $0 }.count == 1, "Exactly one concurrent creator wins")
        let listing = try service.transport.listDirectory(endpoint: source.endpoint, directory: root.path)
        try require(listing.contains(where: { $0.name == "draft '中文.txt" }) == false && listing.contains(where: { $0.name == "renamed.txt" }), "NUL-delimited listing keeps paths intact")
        try require(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".zshell-file-") }, "Capability and save temporaries are cleaned")
        let missing = RemoteFileService(transport: OpenSSHTransport(executableURL: URL(fileURLWithPath: CommandLine.arguments[3])))
        try require(try missing.capabilities(source: source) == .unavailable, "Missing Perl disables writes without installing anything")
        try require(try !missing.transport.listDirectory(endpoint: source.endpoint, directory: root.path).isEmpty, "Tree browsing works without Perl")
        let limited = RemoteFileService(transport: OpenSSHTransport(executableURL: URL(fileURLWithPath: CommandLine.arguments[4])))
        let limitedCapabilities = try limited.capabilities(source: source)
        try require(limitedCapabilities.create && !limitedCapabilities.rename && !limitedCapabilities.trash && !limitedCapabilities.save,
                    "Missing atomic rename disables only unsupported operations")
        try require(try limited.read(source: source, path: collision).text == "preserve", "Reads remain available without atomic rename")
        try rejects(.unsupported) { _ = try limited.rename(source: source, path: collision, name: "unsafe-rename.txt") }
        try require(try String(contentsOfFile: collision, encoding: .utf8) == "preserve", "Disabled operations leave files unchanged")
        let home = temporary.appendingPathComponent("remote-home")
        let homeSource = RemoteFileSource(endpoint: source.endpoint, root: "~")
        try require(try service.capabilities(source: homeSource).save, "Bare tilde is expanded before the anchored helper runs")
        let homeFile = try service.create(source: homeSource, directory: "~", name: "home.txt", isDirectory: false)
        try require(try service.read(source: homeSource, path: homeFile).isRegular && fm.fileExists(atPath: home.appendingPathComponent("home.txt").path),
                    "Bare tilde create/read use the remote home")
        let unicodeHome = home.appendingPathComponent("项目 with spaces")
        try fm.createDirectory(at: unicodeHome, withIntermediateDirectories: false)
        let nestedSource = RemoteFileSource(endpoint: source.endpoint, root: "~/项目 with spaces")
        let nestedFile = try service.create(source: nestedSource, directory: nestedSource.root, name: "tilde.txt", isDirectory: false)
        let nestedBaseline = try service.read(source: nestedSource, path: nestedFile)
        guard case .saved(let nestedSaved) = try service.save(source: nestedSource, path: nestedFile, text: "tilde", baseline: nestedBaseline) else { fatalError("Tilde save conflicted") }
        try require(nestedSaved.text == "tilde" && nestedSaved.path == nestedFile && nestedSaved.root == unicodeHome.path,
                    "Tilde unicode paths keep logical paths and canonical root identity consistent")
        let namedDirectory = URL(fileURLWithPath: CommandLine.arguments[5])
        let namedSource = RemoteFileSource(endpoint: source.endpoint, root: "~" + NSUserName())
        let namedParent = namedSource.root + "/" + namedDirectory.lastPathComponent
        let namedFile = try service.create(source: namedSource, directory: namedParent, name: "named.txt", isDirectory: false)
        try require(try service.read(source: namedSource, path: namedFile).isRegular && fm.fileExists(atPath: namedDirectory.appendingPathComponent("named.txt").path),
                    "Named-user tilde roots expand through the existing quoting path")
        let namedNestedSource = RemoteFileSource(endpoint: source.endpoint, root: namedParent)
        let namedBaseline = try service.read(source: namedNestedSource, path: namedFile)
        guard case .saved(let namedSaved) = try service.save(source: namedNestedSource, path: namedFile, text: "named", baseline: namedBaseline) else { fatalError("Named tilde save conflicted") }
        try require(namedSaved.text == "named", "Named-user tilde subdirectories support safe saves")
        print("Remote file operations: \(checks) checks passed; no GUI, server, network, credentials, or retained binary")
    }
}
