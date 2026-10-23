import Foundation
import Darwin

@main
struct AgentTurnReviewTests {
    @MainActor
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("zshell-turn-review-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = temporary.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
        let root = repository.path
        func git(_ arguments: [String]) throws -> Data {
            try AgentReviewGit.command(arguments, in: root)
        }
        func write(_ path: String, _ value: String) throws {
            try Data(value.utf8).write(to: repository.appendingPathComponent(path))
        }
        func read(_ path: String) throws -> Data {
            try Data(contentsOf: repository.appendingPathComponent(path))
        }
        func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
        func expectFailure(_ body: () throws -> Void) throws {
            do { try body() } catch { return }
            fatalError("An unsafe operation was accepted")
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Review Tests"])
        _ = try git(["config", "user.email", "review@example.invalid"])
        let original = (1...80).map { "line \($0)\n" }.joined()
        try write("tracked.txt", original)
        try write("deleted.txt", "restore this\n")
        try write("no-newline.txt", "old")
        try write("crlf.txt", "old\r\nother\r\n")
        try write(".gitignore", "ignored.txt\n")
        try Data([0, 1, 2]).write(to: repository.appendingPathComponent("binary.bin"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "fixture"])
        let staged = original.replacingOccurrences(of: "line 4\n", with: "user staged\n")
        try write("tracked.txt", staged)
        _ = try git(["add", "tracked.txt"])
        let baselineText = staged.replacingOccurrences(of: "line 5\n", with: "user unstaged\n")
        try write("tracked.txt", baselineText)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: repository.appendingPathComponent("tracked.txt").path)
        let attribute = Data("preserve review metadata".utf8)
        precondition(attribute.withUnsafeBytes {
            setxattr(repository.appendingPathComponent("tracked.txt").path, "com.zshell.review-test", $0.baseAddress, attribute.count, 0, 0)
        } == 0)
        try write("existing untracked.txt", "user draft\n")
        try write("ignored.txt", "must stay ignored\n")
        let index = try read(".git/index")
        let before = try AgentReviewGit.capture(in: root)
        check(try read(".git/index") == index)
        let changedText = baselineText.replacingOccurrences(of: "line 20\n", with: "agent first\n")
            .replacingOccurrences(of: "line 60\n", with: "agent second\n")
        try write("tracked.txt", changedText)
        try write("new\n路径.txt", "new content\n")
        try write("existing untracked.txt", "user draft\nagent added\n")
        try write("no-newline.txt", "new")
        try write("crlf.txt", "new\r\nother\r\n")
        try FileManager.default.removeItem(at: repository.appendingPathComponent("deleted.txt"))
        try Data([0, 3, 4]).write(to: repository.appendingPathComponent("binary.bin"))
        try Data(repeating: 65, count: AgentReviewGit.maxFileBytes + 1)
            .write(to: repository.appendingPathComponent("large.txt"))
        try FileManager.default.createSymbolicLink(atPath: repository.appendingPathComponent("link.txt").path, withDestinationPath: "/etc/hosts")
        let after = try AgentReviewGit.capture(in: root)
        check(try read(".git/index") == index)
        let files = try AgentReviewGit.files(from: before, to: after)
        precondition(!files.contains { $0.path == "ignored.txt" })
        precondition(files.first { $0.path == "large.txt" }?.excluded == true)
        precondition(files.first { $0.path == "link.txt" }?.excluded == true)
        let file = files.first { $0.path == "tracked.txt" }!
        let contents = try AgentReviewGit.contents(for: file, before: before, after: after)
        precondition(contents.before == Data(baselineText.utf8))
        precondition(contents.hunks.count == 2)
        let first = contents.hunks[0]
        let second = contents.hunks[1]
        try AgentReviewGit.revert(file: file, contents: contents, hunk: first, revertedIDs: [], before: before, after: after)
        let partial = try read("tracked.txt")
        precondition(String(decoding: partial, as: UTF8.self).contains("agent second"))
        precondition(!String(decoding: partial, as: UTF8.self).contains("agent first"))
        try write("tracked.txt", String(decoding: partial, as: UTF8.self) + "later user edit\n")
        let later = try read("tracked.txt")
        try expectFailure {
            try AgentReviewGit.revert(file: file, contents: contents, hunk: second, revertedIDs: [first.id], before: before, after: after)
        }
        check(try read("tracked.txt") == later)
        try partial.write(to: repository.appendingPathComponent("tracked.txt"))
        try AgentReviewGit.revert(file: file, contents: contents, hunk: second, revertedIDs: [first.id], before: before, after: after)
        check(try read("tracked.txt") == Data(baselineText.utf8))
        check(try AgentReviewGit.readFile(root: root, path: "tracked.txt")?.permissions == 0o640)
        var savedAttribute = Data(count: attribute.count)
        let attributeCount = savedAttribute.withUnsafeMutableBytes {
            getxattr(repository.appendingPathComponent("tracked.txt").path, "com.zshell.review-test", $0.baseAddress, attribute.count, 0, 0)
        }
        precondition(attributeCount == attribute.count && savedAttribute == attribute)
        check(try read(".git/index") == index)

        for path in ["new\n路径.txt", "deleted.txt", "no-newline.txt", "crlf.txt", "existing untracked.txt"] {
            let entry = files.first { $0.path == path }!
            let data = try AgentReviewGit.contents(for: entry, before: before, after: after)
            precondition(data.hunks.count == 1, path)
            try AgentReviewGit.revert(file: entry, contents: data, hunk: data.hunks[0], revertedIDs: [], before: before, after: after)
            check(try AgentReviewGit.readFile(root: root, path: path)?.data == data.before, path)
        }
        let binary = files.first { $0.path == "binary.bin" }!
        let binaryContents = try AgentReviewGit.contents(for: binary, before: before, after: after)
        precondition(binaryContents.hunks.isEmpty)
        try expectFailure {
            try AgentReviewGit.revert(file: binary, contents: binaryContents, hunk: first, revertedIDs: [], before: before, after: after)
        }
        try expectFailure { _ = try AgentReviewGit.readFile(root: root, path: "../outside") }

        _ = try git(["switch", "-qc", "feature"])
        try write("committed.txt", "branch commit\n")
        _ = try git(["add", "committed.txt"])
        _ = try git(["commit", "-qm", "branch"])
        let branchSnapshot = try AgentReviewGit.capture(in: root)
        let uncommittedBase = try AgentReviewGit.comparisonBase(in: root, branch: false)
        let branchBase = try AgentReviewGit.comparisonBase(in: root, branch: true, reference: "refs/heads/main")
        let uncommittedFiles = try AgentReviewGit.files(from: uncommittedBase, to: branchSnapshot)
        let branchFiles = try AgentReviewGit.files(from: branchBase, to: branchSnapshot)
        precondition(!uncommittedFiles.contains { $0.path == "committed.txt" })
        precondition(branchFiles.contains { $0.path == "committed.txt" })
        precondition(branchFiles.contains { $0.path == "existing untracked.txt" })
        try expectFailure {
            try AgentReviewGit.revert(file: file, contents: contents, hunk: first, revertedIDs: [], before: before, after: after)
        }

        let store = AgentTurnReviewStore.shared
        let firstSession = UUID()
        await store.begin(sessionID: firstSession, alias: "first", directory: root)
        try write("tracked.txt", baselineText.replacingOccurrences(of: "line 20\n", with: "store change\n"))
        await store.finish(sessionID: firstSession)
        var turn = store.records(in: root).first { $0.sessionID == firstSession }!
        precondition(!turn.isActive && turn.before != nil && turn.after != nil)
        let storeFile = try AgentReviewGit.files(from: turn.before!, to: turn.after!).first { $0.path == "tracked.txt" }!
        let storeContents = try AgentReviewGit.contents(for: storeFile, before: turn.before!, after: turn.after!)
        let storeHunk = storeContents.hunks[0]
        let indexBeforeKeep = try read(".git/index")
        let beforeKeep = try read("tracked.txt")
        try store.keep(turn: turn, file: storeFile, hunk: storeHunk)
        check(try read("tracked.txt") == beforeKeep)
        check(try read(".git/index") == indexBeforeKeep)
        let secondSession = UUID()
        await store.begin(sessionID: secondSession, alias: "second", directory: root)
        do {
            try await store.revert(turn: turn, file: storeFile, contents: storeContents, hunk: storeHunk)
            fatalError("An active agent did not block revert")
        } catch AgentReviewError.active {}
        await store.finish(sessionID: secondSession)
        store.activeAgentCheck = { _ in true }
        do {
            try await store.revert(turn: turn, file: storeFile, contents: storeContents, hunk: storeHunk)
            fatalError("An agent without a review record did not block revert")
        } catch AgentReviewError.active {}
        store.activeAgentCheck = nil
        try await store.revert(turn: turn, file: storeFile, contents: storeContents, hunk: storeHunk)
        turn = store.records(in: root).first { $0.sessionID == firstSession }!
        precondition(turn.reverted.contains(AgentTurnReviewStore.decisionKey(file: storeFile, hunk: storeHunk)))
        check(try read(".git/index") == indexBeforeKeep)

        await store.begin(sessionID: firstSession, alias: "first", directory: root)
        await store.begin(sessionID: secondSession, alias: "second", directory: root)
        try write("tracked.txt", baselineText + "concurrent\n")
        await store.finish(sessionID: secondSession)
        await store.finish(sessionID: firstSession)
        turn = store.records(in: root).first { $0.sessionID == secondSession }!
        precondition(turn.overlapped)
        let concurrentFile = try AgentReviewGit.files(from: turn.before!, to: turn.after!).first { $0.path == "tracked.txt" }!
        let concurrentContents = try AgentReviewGit.contents(for: concurrentFile, before: turn.before!, after: turn.after!)
        do {
            try await store.revert(turn: turn, file: concurrentFile, contents: concurrentContents, hunk: concurrentContents.hunks[0])
            fatalError("An overlapping turn allowed revert")
        } catch AgentReviewError.overlapping {}
        await store.begin(sessionID: firstSession, alias: "first", directory: root)
        store.abort(sessionID: firstSession)
        turn = store.records(in: root).first { $0.sessionID == firstSession }!
        precondition(!turn.isActive && turn.failure != nil)

        let folder = repository.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write("folder/file.txt", "before\n")
        let safeBefore = try AgentReviewGit.capture(in: root)
        try write("folder/file.txt", "after\n")
        let safeAfter = try AgentReviewGit.capture(in: root)
        let safeFile = try AgentReviewGit.files(from: safeBefore, to: safeAfter).first { $0.path == "folder/file.txt" }!
        let safeContents = try AgentReviewGit.contents(for: safeFile, before: safeBefore, after: safeAfter)
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside must stay\n".utf8).write(to: outside.appendingPathComponent("file.txt"))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        try expectFailure {
            try AgentReviewGit.revert(file: safeFile, contents: safeContents, hunk: safeContents.hunks[0], revertedIDs: [], before: safeBefore, after: safeAfter)
        }
        check(try Data(contentsOf: outside.appendingPathComponent("file.txt")) == Data("outside must stay\n".utf8))

        let unborn = temporary.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: false)
        _ = try AgentReviewGit.command(["init", "-q"], in: unborn.path)
        let empty = try AgentReviewGit.capture(in: unborn.path)
        try Data("new unborn\n".utf8).write(to: unborn.appendingPathComponent("new.txt"))
        let populated = try AgentReviewGit.capture(in: unborn.path)
        let unbornFile = try AgentReviewGit.files(from: empty, to: populated)[0]
        let unbornContents = try AgentReviewGit.contents(for: unbornFile, before: empty, after: populated)
        try AgentReviewGit.revert(file: unbornFile, contents: unbornContents, hunk: unbornContents.hunks[0], revertedIDs: [], before: empty, after: populated)
        precondition(!FileManager.default.fileExists(atPath: unborn.appendingPathComponent("new.txt").path))
        precondition(!FileManager.default.fileExists(atPath: unborn.appendingPathComponent(".git/index").path))
        for index in 0...AgentReviewGit.maxPaths {
            try Data().write(to: unborn.appendingPathComponent("path-\(index)"))
        }
        try expectFailure { _ = try AgentReviewGit.capture(in: unborn.path) }
        precondition(!FileManager.default.fileExists(atPath: unborn.appendingPathComponent(".git/index").path))
        print("Agent turn review: snapshot/index isolation, temporal scopes, hunk reversal, CRLF/EOF, untracked/deleted/binary/oversize/symlink, stale HEAD/content, Keep, active and concurrent turn guards passed")
    }
}
