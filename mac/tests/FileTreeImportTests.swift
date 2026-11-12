import Darwin
import Foundation
import Synchronization

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private nonisolated func require(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(description: message) }
}

nonisolated enum ImportRollbackRaceFixture {
    static let action = Mutex<(@Sendable (FileTreeImportService.Plan) -> Void)?>(nil)
    static func afterPublish(_ plan: FileTreeImportService.Plan) {
        action.withLock { $0 }?(plan)
    }
}

@main
struct FileTreeImportTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zshell-file-import-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let outside = root.appendingPathComponent("outside")
        for directory in [source, target, outside] { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        func file(_ directory: URL, _ name: String, _ contents: String = "new") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }
        func read(_ directory: URL, _ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        func run(_ urls: [URL], decisions: [Int: FileTreeImportService.Decision] = [:],
                 operation: FileTreeImportOperation = FileTreeImportOperation(), destination: URL? = nil) throws -> [String] {
            let plan = try FileTreeImportService.prepare(sources: urls, root: target.path,
                                                        directory: (destination ?? target).path, operation: operation)
            return try FileTreeImportService.perform(plan, decisions: decisions, operation: operation)
        }
        func fails(_ message: String, _ body: () throws -> Void) throws {
            do { try body() }
            catch { print("PASS: " + message); return }
            throw TestFailure(description: message + " unexpectedly succeeded")
        }
        func cleanStaging() throws {
            try require(!fm.contentsOfDirectory(atPath: target.path).contains { $0.hasPrefix(".zshell-import-") }, "No staging leftovers")
        }
        func rejectsRecursion(_ source: URL, root: URL, directory: URL, _ message: String) throws {
            let contents = try fm.contentsOfDirectory(atPath: directory.path)
            do {
                _ = try FileTreeImportService.prepare(sources: [source], root: root.path, directory: directory.path,
                                                      operation: FileTreeImportOperation())
                throw TestFailure(description: message + " unexpectedly accepted")
            } catch FileTreeImportService.Failure.recursiveCopy(let name) {
                try require(name == source.lastPathComponent, "Recursive error names the source")
            }
            try require(fm.contentsOfDirectory(atPath: directory.path) == contents, "Recursive import never creates staging")
            print("PASS: " + message)
        }

        let plain = try file(source, "plain.txt", "original")
        let projects = root.appendingPathComponent("Projects")
        let imports = projects.appendingPathComponent("Imports")
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        let suppliedRoot = root.appendingPathComponent("projects")
        let suppliedDirectory = suppliedRoot.appendingPathComponent("imports")
        if fm.fileExists(atPath: suppliedDirectory.path) {
            let casePlan = try FileTreeImportService.prepare(sources: [plain], root: suppliedRoot.path,
                                                            directory: suppliedDirectory.path, operation: FileTreeImportOperation())
            _ = try FileTreeImportService.perform(casePlan, decisions: [:], operation: FileTreeImportOperation())
            try require(read(imports, "plain.txt") == "original", "Case-insensitive destination spelling imports into the same node")
            try rejectsRecursion(projects, root: suppliedRoot, directory: suppliedDirectory,
                                 "case-insensitive descendant recursion rejected before staging")
            try rejectsRecursion(projects, root: suppliedRoot, directory: suppliedRoot,
                                 "case-insensitive same-directory recursion rejected before staging")
            let mixedDestination = try FileTreeImportService.destination(root: suppliedRoot.path, directory: imports.path)
            try require(mixedDestination.directorySnapshot.sameNode(as: casePlan.destination.directorySnapshot),
                        "Mixed-case root and descendant identify the same destination")
            let mixedRoot = try FileTreeImportService.destination(root: projects.path, directory: suppliedRoot.path)
            try require(mixedRoot.rootSnapshot.sameNode(as: mixedRoot.directorySnapshot),
                        "Mixed-case root and same directory are accepted")
            print("PASS: mixed-case root containment uses node identity")
            let next = try file(source, "case-next.txt")
            let beforeMove = try FileTreeImportService.prepare(sources: [next], root: suppliedRoot.path,
                                                              directory: suppliedDirectory.path, operation: FileTreeImportOperation())
            let moved = projects.appendingPathComponent("Moved")
            try fm.moveItem(at: imports, to: moved)
            try fails("case-insensitive destination moved after planning") {
                _ = try FileTreeImportService.perform(beforeMove, decisions: [:], operation: FileTreeImportOperation())
            }
            try fm.createDirectory(at: imports, withIntermediateDirectories: false)
            try fails("case-insensitive destination replaced after planning") {
                _ = try FileTreeImportService.perform(beforeMove, decisions: [:], operation: FileTreeImportOperation())
            }
            try require(!fm.fileExists(atPath: moved.appendingPathComponent("case-next.txt").path)
                        && fm.contentsOfDirectory(atPath: imports.path).isEmpty, "Moved and replacement directories remain unchanged")
            print("PASS: actual case-insensitive directory spelling and retained node identity protection")
        } else { print("SKIP: case-insensitive directory spelling on a case-sensitive volume") }
        try require(run([plain]).count == 1, "Copy plain file")
        try require(read(target, "plain.txt") == "original" && read(source, "plain.txt") == "original", "Source survives copy")
        let folder = source.appendingPathComponent("folder")
        try fm.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        _ = try file(folder.appendingPathComponent("nested"), "中文.txt", "nested")
        try require(run([folder]).count == 1, "Copy nested folder")
        try require(read(target.appendingPathComponent("folder/nested"), "中文.txt") == "nested", "Nested unicode contents")
        print("PASS: file, nested folder, unicode and source preservation")
        let sibling = source.appendingPathComponent("folder-other")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: false)
        let siblingPlan = try FileTreeImportService.prepare(sources: [folder], root: source.path, directory: sibling.path,
                                                           operation: FileTreeImportOperation())
        _ = try FileTreeImportService.perform(siblingPlan, decisions: [:], operation: FileTreeImportOperation())
        try require(read(sibling.appendingPathComponent("folder/nested"), "中文.txt") == "nested",
                    "Sibling destination with a shared name prefix accepts the folder copy")
        print("PASS: sibling folder import remains allowed")

        try Data("replacement".utf8).write(to: plain)
        let collision = try FileTreeImportService.prepare(sources: [plain], root: target.path, directory: target.path,
                                                          operation: FileTreeImportOperation())
        try require(collision.conflicts == [0], "Conflict captured before write")
        try require(FileTreeImportService.perform(collision, decisions: [0: .skip], operation: FileTreeImportOperation()).isEmpty,
                    "Skip produces no import")
        try require(read(target, "plain.txt") == "original", "Skip preserves existing content")
        try require(FileTreeImportService.perform(collision, decisions: [0: .replace], operation: FileTreeImportOperation()).count == 1,
                    "Explicit replace imports")
        try require(read(target, "plain.txt") == "replacement", "Replace updates content")
        print("PASS: Replace and Skip")
        try cleanStaging()

        let directoryCollisionPlan = try FileTreeImportService.prepare(sources: [folder], root: target.path, directory: target.path,
                                                                       operation: FileTreeImportOperation())
        let directoryEdit = target.appendingPathComponent("folder/nested/中文.txt")
        try Data("external-nested".utf8).write(to: directoryEdit)
        try fails("nested destination edit before folder replacement") {
            _ = try FileTreeImportService.perform(directoryCollisionPlan, decisions: [0: .replace], operation: FileTreeImportOperation())
        }
        try require(read(target.appendingPathComponent("folder/nested"), "中文.txt") == "external-nested", "Nested concurrent edit survives")
        try cleanStaging()

        try fails("missing conflict decision") { _ = try run([plain]) }
        try fails("same folder and hard-link self copy") { _ = try run([target.appendingPathComponent("plain.txt")], decisions: [0: .replace]) }
        let hardLink = source.appendingPathComponent("hard.txt")
        try fm.linkItem(at: target.appendingPathComponent("plain.txt"), to: hardLink)
        try fm.linkItem(at: hardLink, to: target.appendingPathComponent("hard.txt"))
        try fails("hard link identity") { _ = try run([hardLink], decisions: [0: .replace]) }
        try fails("outside root destination") { _ = try run([plain], destination: outside) }
        let aliasDirectory = target.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: aliasDirectory, withDestinationURL: outside)
        try fails("target directory symlink escape") { _ = try run([plain], destination: aliasDirectory) }
        try rejectsRecursion(target, root: target, directory: target, "directory self recursion")
        let targetFolder = target.appendingPathComponent("folder")
        let targetNested = targetFolder.appendingPathComponent("nested")
        try rejectsRecursion(targetFolder, root: target, directory: targetNested, "directory descendant recursion")
        let nestedLink = target.appendingPathComponent("nested-link")
        try fm.createSymbolicLink(at: nestedLink, withDestinationURL: targetNested)
        try rejectsRecursion(targetFolder, root: target, directory: nestedLink, "symlink-resolved descendant recursion")
        let linkedPlan = try FileTreeImportService.prepare(sources: [plain], root: target.path, directory: nestedLink.path,
                                                          operation: FileTreeImportOperation())
        try fm.removeItem(at: nestedLink)
        try fm.createSymbolicLink(at: nestedLink, withDestinationURL: outside)
        try fails("destination symlink changed after planning") {
            _ = try FileTreeImportService.perform(linkedPlan, decisions: [:], operation: FileTreeImportOperation())
        }
        try require(!fm.fileExists(atPath: targetNested.appendingPathComponent("plain.txt").path)
                    && fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Changed destination link publishes no copies")
        let another = root.appendingPathComponent("another")
        try fm.createDirectory(at: another, withIntermediateDirectories: false)
        let duplicate = try file(another, "plain.txt")
        try fails("duplicate source names") { _ = try run([plain, duplicate]) }

        let link = source.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
        _ = try run([link])
        try require(fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path) == "missing-target", "Dangling symbolic link copied verbatim")
        let loop = folder.appendingPathComponent("loop")
        try fm.createSymbolicLink(at: loop, withDestinationURL: folder)
        _ = try run([folder], decisions: [0: .replace])
        try require(fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("folder/loop").path) == folder.path, "Directory link not traversed")
        print("PASS: symbolic links, dangling links and cycles")
        try cleanStaging()

        let cancelOp = FileTreeImportOperation()
        cancelOp.cancel()
        try fails("cancel before copy") { _ = try run([plain], decisions: [0: .replace], operation: cancelOp) }
        let cancellationHolder = Mutex<FileTreeImportOperation?>(nil)
        let cancellation = FileTreeImportOperation { _ in cancellationHolder.withLock { $0?.cancel() } }
        cancellationHolder.withLock { $0 = cancellation }
        let cancelledFile = try file(source, "cancelled.txt")
        try fails("cancel during staging") { _ = try run([cancelledFile], operation: cancellation) }
        try require(!fm.fileExists(atPath: target.appendingPathComponent("cancelled.txt").path), "Cancelled copy is unpublished")
        try cleanStaging()

        let cancelledAddition = try file(source, "cancelled-addition.txt")
        let cancelledReplacement = try file(source, "cancelled-replacement.txt", "new replacement")
        _ = try file(target, "cancelled-replacement.txt", "old replacement")
        let cancelledPlan = try FileTreeImportService.prepare(sources: [cancelledAddition, cancelledReplacement],
                                                              root: target.path, directory: target.path,
                                                              operation: FileTreeImportOperation())
        let afterPublishOperation = FileTreeImportOperation()
        ImportRollbackRaceFixture.action.withLock { $0 = { _ in afterPublishOperation.cancel() } }
        var rolledBackCancellation = false
        do {
            _ = try FileTreeImportService.perform(cancelledPlan, decisions: [1: .replace], operation: afterPublishOperation)
        } catch is CancellationError { rolledBackCancellation = true }
        ImportRollbackRaceFixture.action.withLock { $0 = nil }
        try require(rolledBackCancellation && !fm.fileExists(atPath: target.appendingPathComponent("cancelled-addition.txt").path)
                    && read(target, "cancelled-replacement.txt") == "old replacement",
                    "Cancellation removes added copies and restores unchanged replacements")
        try require(read(source, "cancelled-addition.txt") == "new" && read(source, "cancelled-replacement.txt") == "new replacement",
                    "Cancellation preserves both source files")
        try cleanStaging()
        print("PASS: cancellation rolls back added and replaced items after publication")

        let raceFile = try file(source, "raced.txt")
        let racePlan = try FileTreeImportService.prepare(sources: [raceFile], root: target.path, directory: target.path,
                                                        operation: FileTreeImportOperation())
        _ = try file(target, "raced.txt", "concurrent")
        try fails("new destination collision after planning") {
            _ = try FileTreeImportService.perform(racePlan, decisions: [:], operation: FileTreeImportOperation())
        }
        try require(read(target, "raced.txt") == "concurrent", "Concurrent data survives")
        try cleanStaging()

        let first = try file(source, "first.txt")
        let second = try file(source, "second.txt")
        _ = try file(target, "first.txt", "old-first")
        _ = try file(target, "second.txt", "old-second")
        let rollbackPlan = try FileTreeImportService.prepare(sources: [first, second], root: target.path, directory: target.path,
                                                            operation: FileTreeImportOperation())
        let mutate = FileTreeImportOperation { name in
            if name == "second.txt" { try? Data("external-second".utf8).write(to: target.appendingPathComponent("second.txt")) }
        }
        try fails("rollback earlier replacement after a later race") {
            _ = try FileTreeImportService.perform(rollbackPlan, decisions: [0: .replace, 1: .replace], operation: mutate)
        }
        try require(read(target, "first.txt") == "old-first" && read(target, "second.txt") == "external-second", "Rollback restores first and preserves concurrent second")
        try cleanStaging()

        let newlyAdded = try file(source, "changed-after-publish.txt")
        let incompletePlan = try FileTreeImportService.prepare(sources: [newlyAdded], root: target.path, directory: target.path,
                                                              operation: FileTreeImportOperation())
        let incompleteOperation = FileTreeImportOperation()
        ImportRollbackRaceFixture.action.withLock { action in
            action = { _ in
                try? Data("concurrent edit survives".utf8).write(to: target.appendingPathComponent("changed-after-publish.txt"))
                incompleteOperation.cancel()
            }
        }
        var recoveryPath: String?
        do {
            _ = try FileTreeImportService.perform(incompletePlan, decisions: [:], operation: incompleteOperation)
        } catch FileTreeImportService.Failure.recovery(let path) { recoveryPath = path }
        ImportRollbackRaceFixture.action.withLock { $0 = nil }
        try require(read(target, "changed-after-publish.txt") == "concurrent edit survives", "Changed newly imported item survives cancellation")
        guard let recoveryPath else { throw TestFailure(description: "Incomplete rollback must report recovery") }
        try require(fm.contentsOfDirectory(atPath: recoveryPath + "/originals").isEmpty
                    && !fm.fileExists(atPath: recoveryPath + "/incoming/changed-after-publish.txt"),
                    "A changed new import has no guaranteed saved copy")
        let recoveryMessage = FileTreeImportService.Failure.recovery(recoveryPath).localizedDescription
        try require(recoveryMessage.contains("could not be fully undone") && recoveryMessage.contains("may be available"),
                    "Recovery message qualifies incomplete rollback and available files")
        try fm.removeItem(atPath: recoveryPath)
        try cleanStaging()
        print("PASS: cancellation preserves concurrent import edits and recovery folder may contain no saved copy")

        let changedPlan = try FileTreeImportService.prepare(sources: [first], root: target.path, directory: target.path,
                                                           operation: FileTreeImportOperation())
        try Data("changed-source".utf8).write(to: first)
        try fails("source changed after planning") {
            _ = try FileTreeImportService.perform(changedPlan, decisions: [0: .replace], operation: FileTreeImportOperation())
        }
        try cleanStaging()

        let movingDirectory = target.appendingPathComponent("moving")
        try fm.createDirectory(at: movingDirectory, withIntermediateDirectories: false)
        let movingPlan = try FileTreeImportService.prepare(sources: [second], root: target.path, directory: movingDirectory.path,
                                                          operation: FileTreeImportOperation())
        let movedDirectory = target.appendingPathComponent("moved")
        try fm.moveItem(at: movingDirectory, to: movedDirectory)
        try fm.createDirectory(at: movingDirectory, withIntermediateDirectories: false)
        try fails("destination directory identity changed") {
            _ = try FileTreeImportService.perform(movingPlan, decisions: [:], operation: FileTreeImportOperation())
        }
        try require(fm.contentsOfDirectory(atPath: movingDirectory.path).isEmpty && fm.contentsOfDirectory(atPath: movedDirectory.path).isEmpty,
                    "Neither old nor new destination gains copies")

        let selectionDestination = try FileTreeImportService.destination(root: target.path, directory: movingDirectory.path)
        try fm.moveItem(at: movingDirectory, to: target.appendingPathComponent("moved-again"))
        try fm.createDirectory(at: movingDirectory, withIntermediateDirectories: false)
        try fails("destination replaced while file selection is open") {
            _ = try FileTreeImportService.prepare(sources: [second], root: target.path, directory: movingDirectory.path,
                                                 operation: FileTreeImportOperation(), destination: selectionDestination)
        }
        try require(fm.contentsOfDirectory(atPath: movingDirectory.path).isEmpty, "Selection never imports into replacement folder")

        let alias = source.appendingPathComponent("Finder Alias")
        let aliasData = try plain.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(aliasData, to: alias)
        _ = try run([alias])
        try require(Data(contentsOf: alias) == Data(contentsOf: target.appendingPathComponent("Finder Alias")), "Finder alias copied as an item")
        print("PASS: Finder aliases copied without resolving the leaf")

        let deep = source.appendingPathComponent("deep")
        var nested = deep
        for _ in 0..<(FileTreeImportService.maximumDepth + 2) {
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            nested.appendPathComponent("d")
        }
        try fails("bounded directory depth") { _ = try run([deep]) }
        try require(!fm.fileExists(atPath: target.appendingPathComponent("deep").path), "Depth limit leaves no destination")
        try cleanStaging()

        let unreadable = try file(source, "unreadable.txt")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        if geteuid() != 0 { try fails("source permission error") { _ = try run([unreadable]) } }
        try cleanStaging()

        let fifo = source.appendingPathComponent("fifo")
        try require(mkfifo(fifo.path, 0o600) == 0, "Create FIFO")
        try fails("special file refusal without blocking") { _ = try run([fifo]) }

        let large = source.appendingPathComponent("large")
        try fm.createDirectory(at: large, withIntermediateDirectories: false)
        for index in 0..<2_000 { _ = try file(large, "file-\(index).txt") }
        let begin = ContinuousClock.now
        _ = try run([large])
        try require(fm.contentsOfDirectory(atPath: target.appendingPathComponent("large").path).count == 2_000, "Large directory copied fully")
        print("PASS: 2000-file import in \(begin.duration(to: .now))")
        try cleanStaging()
        print("PASS: all file-tree import production filesystem checks")
    }
}
