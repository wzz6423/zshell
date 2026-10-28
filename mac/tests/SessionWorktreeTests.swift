import Foundation

actor WorktreeFaultRunner: GitCommandRunning {
    enum Fault { case add, completedAdd, branchRace, writeDuringAdd, replacedParent, switchedAfterAdd }
    let fault: Fault
    let real = GitCommandRunner()

    init(_ fault: Fault) { self.fault = fault }

    func run(_ args: [String], in directory: String) async -> GitCommandResult {
        if args.first == "branch", fault == .branchRace {
            _ = await real.run(args, in: directory)
            return GitCommandResult(status: 1, stdout: "", stderr: "fixture: another process created the branch")
        }
        if args.starts(with: ["worktree", "add"]) {
            switch fault {
            case .add: return GitCommandResult(status: 1, stdout: "", stderr: "fixture: checkout failed")
            case .completedAdd:
                _ = await real.run(args, in: directory)
                return GitCommandResult(status: 1, stdout: "", stderr: "fixture: failed after checkout")
            case .writeDuringAdd:
                try? Data("keep this data".utf8).write(to: URL(fileURLWithPath: args[3]).appendingPathComponent("keep.txt"))
                return GitCommandResult(status: 1, stdout: "", stderr: "fixture: partial checkout")
            case .replacedParent:
                let parent = URL(fileURLWithPath: args[3]).deletingLastPathComponent()
                try? FileManager.default.moveItem(at: parent, to: URL(fileURLWithPath: parent.path + ".owned"))
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                return GitCommandResult(status: 1, stdout: "", stderr: "fixture: parent replaced")
            case .switchedAfterAdd:
                let result = await real.run(args, in: directory)
                _ = await real.run(["switch", "-qc", "switched-during-creation"], in: args[3])
                return result
            case .branchRace: break
            }
        }
        return await real.run(args, in: directory)
    }
}

@main
@MainActor
struct SessionWorktreeRegression {
    static var checks = 0
    static var failures = 0

    static func check(_ passed: Bool, _ name: String) {
        checks += 1
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(name)")
    }

    static func git(_ directory: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = Array(args)
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SessionWorktreeError(message: String(decoding: error, as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func rejects(_ name: String, _ operation: () async throws -> Void) async {
        do { try await operation(); check(false, name) }
        catch { check(true, name) }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try git(repo, "init", "-q", "--initial-branch=main")
        _ = try git(repo, "config", "user.name", "Worktree Fixture")
        _ = try git(repo, "config", "user.email", "fixture@example.invalid")
        _ = try git(repo, "config", "commit.gpgsign", "false")
        _ = try git(repo, "config", "core.hooksPath", "/dev/null")
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("ignored.txt\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        _ = try git(repo, "add", ".")
        _ = try git(repo, "commit", "-qm", "base")
        let baseHead = try git(repo, "rev-parse", "HEAD")
        _ = try git(repo, "switch", "-qc", "active-feature")
        try Data("active\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        _ = try git(repo, "commit", "-qam", "active feature")
        let currentHead = try git(repo, "rev-parse", "HEAD")
        let service = SessionWorktreeService()
        let repository = try await service.repository(at: repo.path)
        check(repository.defaultReference == "refs/heads/main", "default baseline is main instead of the active feature branch")

        let first = try await service.create(in: repo.path, branch: "feature/new")
        check(first.initialHead == baseHead && first.branch == "feature/new", "new branches start at the default baseline")
        check(first.path == SessionWorktreeService.defaultPath(repositoryRoot: repo.path, branch: "feature/new"), "automatic directory is outside the source checkout")
        check(try git(URL(fileURLWithPath: first.path), "rev-parse", "HEAD") == baseHead, "new worktree checks out the default commit")
        let inspection = try await service.inspect(first)
        check(inspection.canRemove, "clean merged worktree can be removed")
        try await service.remove(first, expected: inspection)
        check(!exists(URL(fileURLWithPath: first.path)), "clean worktree is removed")
        check(try git(repo, "rev-parse", "refs/heads/feature/new") == baseHead, "normal cleanup always preserves its branch")

        let fromCurrent = try await service.create(in: repo.path, branch: "from-current", base: .currentHead)
        check(fromCurrent.initialHead == currentHead && fromCurrent.baseReference == "refs/heads/active-feature", "Current HEAD is an explicit baseline")
        check(!(await service.rollback(fromCurrent, isInUse: { true })), "startup rollback refuses a newly shared worktree")
        check(try git(repo, "rev-parse", "refs/heads/from-current") == currentHead, "shared rollback preserves the created branch")
        check(await service.rollback(fromCurrent), "pristine failed startup can roll back its new worktree")
        await rejects("startup rollback deletes only its own new branch") { _ = try await service.create(in: repo.path, branch: "from-current", requiresExistingBranch: true) }

        _ = try git(repo, "branch", "existing-branch", currentHead)
        let existing = try await service.create(in: repo.path, branch: "existing-branch")
        check(existing.initialHead == currentHead && !existing.createdBranch, "existing branch keeps its current commit")
        check(await service.rollback(existing), "failed startup removes a pristine existing-branch checkout")
        check(try git(repo, "rev-parse", "refs/heads/existing-branch") == currentHead, "startup rollback keeps a pre-existing branch")

        let badNames = ["", "--force", "../escape", "bad name", "bad..name", "bad\nname", "@{-1}"]
        for branch in badNames {
            await rejects("invalid branch is refused: \(branch.debugDescription)") {
                _ = try await service.create(in: repo.path, branch: branch)
            }
        }
        await rejects("checked-out branch is refused") { _ = try await service.create(in: repo.path, branch: "active-feature") }
        await rejects("explicit invalid baseline is refused") { _ = try await service.create(in: repo.path, branch: "bad-base", base: .reference("--help")) }
        await rejects("stale dialog HEAD is refused") { _ = try await service.create(in: repo.path, branch: "stale-head", expectedHead: baseHead) }

        let occupied = root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: occupied.appendingPathComponent("original.txt"))
        await rejects("pre-existing directory is refused") { _ = try await service.create(in: repo.path, branch: "occupied", at: occupied.path) }
        check(try String(contentsOf: occupied.appendingPathComponent("original.txt"), encoding: .utf8) == "original", "existing directory contents stay intact")
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        await rejects("even a pre-existing empty directory is refused") { _ = try await service.create(in: repo.path, branch: "empty", at: empty.path) }
        check(exists(empty), "pre-existing empty directory is not rolled back")
        let link = root.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing-target"))
        await rejects("dangling destination symlink is refused") { _ = try await service.create(in: repo.path, branch: "link", at: link.path) }
        check((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "destination symlink remains untouched")
        await rejects("relative destination is refused") { _ = try await service.create(in: repo.path, branch: "relative", at: "relative") }
        await rejects("directory without a repository is refused") { _ = try await service.create(in: empty.path, branch: "none") }
        await rejects("missing source directory is refused") { _ = try await service.create(in: root.appendingPathComponent("absent").path, branch: "none") }
        let bare = root.appendingPathComponent("bare.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: false)
        _ = try git(bare, "init", "--bare", "-q")
        await rejects("bare repository is explicitly refused") { _ = try await service.create(in: bare.path, branch: "none") }

        for fault in [WorktreeFaultRunner.Fault.add, .completedAdd] {
            let name = fault == .add ? "failed-add" : "failed-after-add"
            let path = root.appendingPathComponent(name + "/parent/checkout")
            let faulty = SessionWorktreeService(runner: WorktreeFaultRunner(fault))
            await rejects("creation failure rolls back: \(name)") { _ = try await faulty.create(in: repo.path, branch: name, at: path.path) }
            check(!exists(path) && !exists(root.appendingPathComponent(name)), "failed creation removes only its newly-created empty parents")
            check((try? git(repo, "rev-parse", "--verify", "refs/heads/\(name)")) == nil, "failed creation removes its unchanged owned branch")
        }
        let race = SessionWorktreeService(runner: WorktreeFaultRunner(.branchRace))
        await rejects("branch race fails safely") { _ = try await race.create(in: repo.path, branch: "raced-branch", at: root.appendingPathComponent("raced").path) }
        check(try git(repo, "rev-parse", "refs/heads/raced-branch") == baseHead, "a branch created by another operation is never rolled back")
        let partialPath = root.appendingPathComponent("partial")
        let partial = SessionWorktreeService(runner: WorktreeFaultRunner(.writeDuringAdd))
        await rejects("failed checkout preserves newly-written data") { _ = try await partial.create(in: repo.path, branch: "partial", at: partialPath.path) }
        check(try String(contentsOf: partialPath.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep this data", "partial-checkout user data is preserved")
        let replacedParent = root.appendingPathComponent("replaced-parent")
        let replacement = SessionWorktreeService(runner: WorktreeFaultRunner(.replacedParent))
        await rejects("creation failure observes parent replacement") {
            _ = try await replacement.create(in: repo.path, branch: "replaced-parent", at: replacedParent.appendingPathComponent("checkout").path)
        }
        check(exists(replacedParent), "rollback preserves an empty parent created by another operation")

        let switchedDuringCreation = root.appendingPathComponent("switched-during-creation")
        let switchedCreation = SessionWorktreeService(runner: WorktreeFaultRunner(.switchedAfterAdd))
        await rejects("creation refuses a checkout whose branch changed during startup") {
            _ = try await switchedCreation.create(in: repo.path, branch: "original-before-switch", at: switchedDuringCreation.path)
        }
        check(exists(switchedDuringCreation), "failed creation preserves a checkout switched by another operation")
        if exists(switchedDuringCreation) {
            check(try git(switchedDuringCreation, "branch", "--show-current") == "switched-during-creation",
                  "failed creation preserves the replacement branch association")
        }

        let stale = try await service.create(in: repo.path, branch: "stale")
        let staleURL = URL(fileURLWithPath: stale.path)
        _ = try git(repo, "worktree", "remove", stale.path)
        _ = try git(repo, "worktree", "add", "--", stale.path, "stale")
        await rejects("recreated worktree cannot reuse a stale session identity") { try await service.remove(stale) }
        check(exists(staleURL), "a replacement worktree with the same path and branch is preserved")
        let current = try await service.association(at: stale.path, sourceDirectory: repo.path)
        var missingIdentity = current
        missingIdentity.gitDirectoryIdentity = nil
        await rejects("legacy metadata alone cannot authorize destructive cleanup") { try await service.remove(missingIdentity) }
        try await service.remove(current)

        let cleanup = try await service.create(in: repo.path, branch: "cleanup")
        let cleanupURL = URL(fileURLWithPath: cleanup.path)
        try Data("changed".utf8).write(to: cleanupURL.appendingPathComponent("tracked.txt"))
        check(try await service.inspect(cleanup).changedPaths == 1, "tracked modifications prevent cleanup")
        await rejects("dirty cleanup is refused before deletion") { try await service.remove(cleanup) }
        check(!(await service.rollback(cleanup)), "failed-start rollback never removes changed worktree data")
        _ = try git(cleanupURL, "restore", "tracked.txt")
        try Data("untracked".utf8).write(to: cleanupURL.appendingPathComponent("untracked.txt"))
        await rejects("untracked file prevents cleanup") { try await service.remove(cleanup) }
        try FileManager.default.removeItem(at: cleanupURL.appendingPathComponent("untracked.txt"))
        try Data("ignored".utf8).write(to: cleanupURL.appendingPathComponent("ignored.txt"))
        await rejects("ignored file prevents cleanup") { try await service.remove(cleanup) }
        check(exists(cleanupURL.appendingPathComponent("ignored.txt")), "ignored user data remains intact")
        try FileManager.default.removeItem(at: cleanupURL.appendingPathComponent("ignored.txt"))
        try Data("commit".utf8).write(to: cleanupURL.appendingPathComponent("tracked.txt"))
        _ = try git(cleanupURL, "commit", "-qam", "worktree commit")
        check(try await service.inspect(cleanup).unmergedCommits == 1, "unmerged commit is reported")
        await rejects("unmerged branch refuses default cleanup") { try await service.remove(cleanup) }
        _ = try git(repo, "switch", "-q", "main")
        _ = try git(repo, "merge", "--ff-only", "-q", "cleanup")
        let clean = try await service.inspect(cleanup)
        check(clean.canRemove, "merging into the recorded baseline allows cleanup")
        await rejects("another open session prevents cleanup") { try await service.remove(cleanup, isInUse: { true }) }
        check(exists(cleanupURL), "shared worktree remains available")
        _ = try git(repo, "worktree", "lock", cleanup.path)
        await rejects("locked worktree cleanup is refused") { try await service.remove(cleanup) }
        _ = try git(repo, "worktree", "unlock", cleanup.path)
        try Data("later change".utf8).write(to: cleanupURL.appendingPathComponent("tracked.txt"))
        await rejects("changed safety snapshot is refused") { try await service.remove(cleanup, expected: clean) }
        _ = try git(cleanupURL, "restore", "tracked.txt")
        try await service.remove(cleanup)
        check(try git(repo, "rev-parse", "refs/heads/cleanup") != "", "merged cleanup keeps committed branch history")
        try FileManager.default.createDirectory(at: cleanupURL, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: cleanupURL.appendingPathComponent("keep.txt"))
        await rejects("reused worktree path is refused") { try await service.remove(cleanup) }
        check(exists(cleanupURL.appendingPathComponent("keep.txt")), "unrelated replacement directory is not deleted")

        let switched = try await service.create(in: repo.path, branch: "switched")
        _ = try git(URL(fileURLWithPath: switched.path), "switch", "-qc", "another-branch")
        await rejects("changed branch association is refused") { try await service.remove(switched) }
        _ = try git(URL(fileURLWithPath: switched.path), "switch", "-q", "switched")
        try await service.remove(switched)
        await rejects("primary checkout cannot get a removable association") { _ = try await service.association(at: repo.path, sourceDirectory: repo.path) }

        _ = try git(repo, "remote", "add", "origin", "https://example.invalid/fixture.git")
        _ = try git(repo, "branch", "trunk")
        _ = try git(repo, "update-ref", "refs/remotes/origin/trunk", "HEAD")
        _ = try git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        check(try await service.repository(at: repo.path).defaultReference == "refs/heads/trunk", "repository's declared default branch takes priority over main")
        _ = try git(repo, "branch", "-D", "trunk")
        check(try await service.repository(at: repo.path).defaultReference == "refs/remotes/origin/trunk", "remote default works when its local branch is absent")

        let customRepo = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: customRepo, withIntermediateDirectories: false)
        _ = try git(customRepo, "init", "-q", "--initial-branch=custom")
        _ = try git(customRepo, "config", "user.name", "Fixture")
        _ = try git(customRepo, "config", "user.email", "fixture@example.invalid")
        _ = try git(customRepo, "config", "commit.gpgsign", "false")
        _ = try git(customRepo, "commit", "--allow-empty", "-qm", "base")
        await rejects("missing default never silently uses the active branch") { _ = try await service.create(in: customRepo.path, branch: "implicit") }
        let explicit = try await service.create(in: customRepo.path, branch: "explicit", base: .currentHead)
        check(explicit.baseReference == "refs/heads/custom", "repository without a default accepts explicit Current HEAD")
        _ = await service.rollback(explicit)

        let encoded = try JSONEncoder().encode(first)
        check(try JSONDecoder().decode(SessionWorktree.self, from: encoded) == first, "worktree identity and baseline survive Codable round trip")
        let paths = "worktree /fixture/new\nline\0HEAD abc\0branch refs/heads/feature/name\0\0worktree /fixture/bare\0bare\0\0"
        let parsed = SessionWorktreeService.parseWorktrees(paths)
        check(parsed.count == 2 && parsed[0].path == "/fixture/new\nline" && parsed[0].branch == "feature/name" && parsed[1].isBare,
              "NUL-delimited worktree records preserve newlines and bare entries")
        check(SessionWorktreeService.contains(cleanupURL.appendingPathComponent("nested").path, in: cleanup.path)
              && !SessionWorktreeService.contains(cleanup.path + "-other", in: cleanup.path), "shared-path checks distinguish siblings from descendants")
        print("\(checks) passed checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
