"""Exercise Git status refreshes and review fingerprints in disposable repositories.

Run: python3 -B mac/tests/test_git_status_snapshot.py
Production Swift slices, binaries, and module caches stay in a temporary folder.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

MAC = Path(__file__).resolve().parents[1]


def slice_between(source, start, end):
    return source[source.index(start):source.index(end)]


class GitStatusSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-status-snapshot-build-")
        cls.addClassCleanup(cls.build.cleanup)
        temporary = Path(cls.build.name)
        model = (MAC / "zshell/GitStatusModel.swift").read_text()
        review = (MAC / "zshell/DiffReview.swift").read_text()
        agent = (MAC / "zshell/AgentTurnReview.swift").read_text()
        types = slice_between(model, "    nonisolated struct Entry:", "    @Published private(set) var rootPath")
        state = slice_between(model, "    @Published private(set) var rootPath", "    /// Branches checked out by a worktree")
        state += '    private var topLevel = ""\n'
        pipe_data = "    private nonisolated final class PipeData:"
        if pipe_data in model:
            state += slice_between(model, pipe_data, "    private func invalidateStatusRefresh()")
        state += slice_between(model, "    /// Runs Git while draining stdout", "    /// Runs Git over SSH")
        result = slice_between(model, "    nonisolated enum StatusLoadResult:", "    /// Runs Git while draining stdout")
        pipeline = model[model.index("    /// Resolves the active repository and distinguishes"):model.index("\nextension GitStatusModel {")]
        apply = slice_between(model, "    private func applyRepository(", "    nonisolated enum StatusLoadResult:")
        helper = temporary / "Support.swift"
        helper.write_text(
            "import Foundation\nimport Combine\nimport CryptoKit\nimport Darwin\n"
            + slice_between(review, "enum DiffReviewLayer:", "@MainActor\nfinal class DiffReviewButton:")
            + slice_between(agent, "nonisolated enum AgentReviewError:", "struct AgentReviewTurn:")
            + "@MainActor final class GitStatusModel {\n"
            + types + state + result
            + apply.replace("private func applyRepository", "func applyRepository")
            + pipeline.replace("private nonisolated static func runGitStatus", "nonisolated static func runGitStatus")
        )
        probe = temporary / "Probe.swift"
        probe.write_text(r'''
import Foundation
import Darwin

@main struct GitStatusSnapshotProbe {
    @MainActor static func main() throws {
        let action = CommandLine.arguments[1]
        let root = CommandLine.arguments[2]
        var commands = 0
        let start = Date()
        func snapshot(failing failedCommand: String? = nil) -> GitStatusModel.StatusResult {
            let load = GitStatusModel.runGitStatus(in: root, recentCommitLimit: 30) { arguments, directory, timeout in
                commands += 1
                if arguments.first == failedCommand {
                    return (-2, "", "fixture detail timeout")
                }
                return GitStatusModel.runGit(arguments, in: directory, timeout: timeout)
            }
            guard case .repository(let value) = load else { fatalError("Status failed: \(load)") }
            return value
        }
        func asJSON(_ snapshot: GitStatusModel.StatusResult) -> [String: Any] {
            let entries = snapshot.entries.map { entry -> [String: Any] in
                var value: [String: Any] = ["path": entry.path, "staged": String(entry.staged),
                    "unstaged": String(entry.unstaged), "conflict": entry.isConflict]
                value["original"] = entry.origPath
                if let fingerprints = snapshot.reviewFingerprints[entry.path] {
                    value["stagedFingerprint"] = fingerprints.staged
                    value["worktreeFingerprint"] = fingerprints.worktree
                }
                return value
            }
            var value: [String: Any] = ["entries": entries, "hasHead": snapshot.hasHead,
                "fingerprints": snapshot.reviewFingerprints.count, "branches": snapshot.branches,
                "remotes": snapshot.remotes, "commits": snapshot.recentCommits.count,
                "worktrees": snapshot.worktrees.count, "stashCount": snapshot.stashCount,
                "details": snapshot.loadedDetails.map { String(describing: $0) }.sorted(),
                "commands": commands, "elapsed": Date().timeIntervalSince(start)]
            value["error"] = snapshot.detailError
            value["defaultBranch"] = snapshot.defaultBranch
            return value
        }
        var output: [String: Any]
        if action == "snapshot" {
            output = asJSON(snapshot())
        } else if action == "fingerprint" {
            let path = CommandLine.arguments[3]
            let layer: DiffReviewLayer = CommandLine.arguments[4] == "staged" ? .staged : .worktree
            let untracked = CommandLine.arguments[5] == "true"
            let original = CommandLine.arguments.count > 6 ? CommandLine.arguments[6] : nil
            let hasHead = GitStatusModel.runGit(["rev-parse", "--verify", "HEAD"], in: root).status == 0
            let digest = DiffReviewFingerprint.load(path: path, originalPath: original, layer: layer,
                hasHead: hasHead, untracked: untracked, in: root) { args, directory in
                    commands += 1
                    return GitStatusModel.runGit(args, in: directory)
                }
            output = ["commands": commands]
            output["fingerprint"] = digest
        } else if action == "failure" {
            let previous = snapshot()
            let model = GitStatusModel()
            model.applyRepository(previous)
            let failed = snapshot(failing: CommandLine.arguments[3])
            model.applyRepository(failed)
            var cached = failed
            cached.preserveUnavailableDetails(from: previous)
            let restored = GitStatusModel()
            restored.applyRepository(cached)
            precondition(model.branches == restored.branches)
            precondition(model.remotes == restored.remotes)
            precondition(model.recentCommits == restored.recentCommits)
            precondition(model.defaultBranch == restored.defaultBranch)
            precondition(model.worktrees == restored.worktrees)
            precondition(model.repositoryOperation == restored.repositoryOperation)
            precondition(model.stashCount == restored.stashCount)
            precondition(model.detailError == "fixture detail timeout")
            precondition(model.statusError == nil && model.isRepo)
            output = asJSON(failed)
            output["appliedBranches"] = model.branches
            output["appliedRemotes"] = model.remotes
            output["appliedCommits"] = model.recentCommits.count
            output["appliedWorktrees"] = model.worktrees.count
            output["appliedDefaultBranch"] = model.defaultBranch
            output["appliedStashCount"] = model.stashCount
            output["cacheRestored"] = true
            var empty = previous
            empty.branches = []
            empty.remotes = []
            empty.recentCommits = []
            empty.worktrees = []
            empty.defaultBranch = nil
            empty.stashCount = 0
            empty.detailError = nil
            model.applyRepository(empty)
            precondition(model.branches.isEmpty && model.remotes.isEmpty && model.recentCommits.isEmpty)
            precondition(model.worktrees.isEmpty && model.defaultBranch == nil && model.stashCount == 0)
            precondition(model.detailError == nil)
            var otherRepository = failed
            otherRepository.topLevel += "-other"
            otherRepository.preserveUnavailableDetails(from: previous)
            precondition(otherRepository.loadedDetails == failed.loadedDetails)
            model.applyRepository(previous)
            var unresolvedRepository = GitStatusModel.StatusResult()
            unresolvedRepository.topLevel = previous.topLevel + "-other"
            model.applyRepository(unresolvedRepository)
            precondition(model.branches.isEmpty && model.remotes.isEmpty && model.recentCommits.isEmpty)
            precondition(model.worktrees.isEmpty && model.defaultBranch == nil && model.stashCount == 0)
        } else if action == "review" {
            let initial = snapshot()
            let model = GitStatusModel()
            model.applyRepository(initial)
            let path = CommandLine.arguments[3]
            let layer = CommandLine.arguments[4] == "staged"
            let entries = layer ? model.stagedEntries : model.changedEntries
            let before = entries.first { $0.path == path }!.reviewSnapshot(staged: layer)!
            DiffReviewStore.shared.setReviewed(true, for: before)
            precondition(DiffReviewStore.shared.isReviewed(before))
            model.applyRepository(snapshot())
            precondition(DiffReviewStore.shared.isReviewed(before), "unchanged review was invalidated")
            try Data("changed after review\n".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(path))
            model.applyRepository(snapshot())
            precondition(DiffReviewStore.shared.isReviewed(before) == layer, "layer invalidation was incorrect")
            output = ["stableBeforeEdit": true, "reviewedAfterWorktreeEdit": layer]
        } else if action == "malformed" {
            let outputWithExtraSection = ":100644 100644 abc 000 M\0one.txt\0\0diff --git a/one.txt b/one.txt\n+text\ndiff --git a/two.txt b/two.txt\n"
            let parsed = DiffReviewFingerprint.trackedPatches(for: ["one.txt"], layer: .worktree, hasHead: true,
                in: root, runGit: { _, _ in (0, outputWithExtraSection, "") })
            precondition(parsed == nil, "malformed patch sections were accepted")
            output = ["rejected": true]
        } else if action == "invalidUTF8" {
            let bytes = Data("# branch.oid abc\0# branch.head main\0? invalid-".utf8) + Data([0xff, 0])
            let decoded = String(data: bytes, encoding: .utf8) ?? ""
            let result = GitStatusModel.runGitStatus(in: root, recentCommitLimit: 30) { arguments, _, _ in
                arguments.first == "rev-parse" ? (0, root + "\n", "") : (0, decoded, "")
            }
            guard case .failed = result else { fatalError("An undecodable status was accepted") }
            let patches = DiffReviewFingerprint.trackedPatches(for: ["safe.txt"], layer: .worktree,
                hasHead: true, in: root, runGit: { _, _ in (0, decoded, "") })
            precondition(DiffReviewFingerprint.fingerprint(path: "safe.txt", originalPath: nil,
                patches: patches ?? [:]) == nil)
            output = ["rejected": true]
        } else { fatalError("Unknown action") }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
''')
        cls.helper = temporary / "git-status-snapshot"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-module-cache-path", str(temporary / "modules"),
            str(MAC / "zshell/GitProxy.swift"), str(MAC / "zshell/GitCommandRunner.swift"),
            str(MAC / "zshell/SessionWorktreeService.swift"), str(helper), str(probe),
            "-o", str(cls.helper),
        ], check=True, cwd=MAC.parent)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="zshell-status-snapshot-fixture-")
        self.addCleanup(self.fixture.cleanup)
        self.repo = Path(self.fixture.name).resolve()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Snapshot Tests")
        self.git("config", "user.email", "snapshot@example.invalid")

    def git(self, *args, check=True):
        return subprocess.run(["/usr/bin/git", *args], cwd=self.repo, check=check,
                              capture_output=True).stdout

    def write(self, path, content):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(content if isinstance(content, bytes) else content.encode())

    def commit_fixture(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.git("branch", "feature-fixture")
        self.git("remote", "add", "origin", "https://example.invalid/fixture.git")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")

    def probe(self, action="snapshot", *args):
        run = subprocess.run([str(self.helper), action, str(self.repo), *args],
                             capture_output=True, text=True, cwd=self.repo, timeout=15)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return json.loads(run.stdout)

    def fingerprints(self):
        return {entry["path"]: entry for entry in self.probe()["entries"]}

    def test_600_untracked_and_tracked_files_keep_complete_snapshot(self):
        self.write("fixture.txt", "fixture\n")
        self.commit_fixture()
        clean = self.probe()
        for index in range(600):
            self.write(f"file-{index:03}.txt", "small change\n")
        for mode in ("untracked", "worktree", "staged"):
            if mode == "worktree":
                self.git("add", ".")
                self.git("commit", "-qm", "files")
                for index in range(600):
                    self.write(f"file-{index:03}.txt", "changed contents\n")
            elif mode == "staged":
                self.git("add", ".")
            snapshot = self.probe()
            self.assertEqual(len(snapshot["entries"]), 600)
            self.assertEqual(snapshot["fingerprints"], 600)
            self.assertEqual(snapshot["branches"], ["feature-fixture", "main"])
            self.assertEqual(snapshot["remotes"], ["origin"])
            self.assertGreaterEqual(snapshot["commits"], 1)
            self.assertEqual(len(snapshot["details"]), 7)
            self.assertNotIn("error", snapshot)
            self.assertLessEqual(snapshot["commands"], clean["commands"] + 2)
            self.assertLess(snapshot["elapsed"], 5)
            print(f"600 {mode}: {snapshot['elapsed']:.3f}s, {snapshot['commands']} Git processes")

    def test_stable_content_changes_and_stage_layers(self):
        self.write("both.txt", "base\n")
        self.commit_fixture()
        self.write("both.txt", "staged\n")
        self.git("add", "both.txt")
        self.write("both.txt", "worktree\n")
        initial = self.fingerprints()["both.txt"]
        self.assertEqual(initial, self.fingerprints()["both.txt"])
        self.write("both.txt", "worktree later\n")
        after = self.fingerprints()["both.txt"]
        self.assertEqual(initial["stagedFingerprint"], after["stagedFingerprint"])
        self.assertNotEqual(initial["worktreeFingerprint"], after["worktreeFingerprint"])
        for layer in ("staged", "worktree"):
            self.assertEqual(after[layer + "Fingerprint"],
                             self.probe("fingerprint", "both.txt", layer, "false")["fingerprint"])
        self.git("add", "both.txt")
        self.assertNotEqual(initial["stagedFingerprint"], self.fingerprints()["both.txt"]["stagedFingerprint"])
        self.write("both.txt", "fresh worktree\n")
        self.assertTrue(self.probe("review", "both.txt", "staged")["reviewedAfterWorktreeEdit"])
        self.write("both.txt", "fresh worktree again\n")
        self.assertFalse(self.probe("review", "both.txt", "worktree")["reviewedAfterWorktreeEdit"])

    def test_paths_binary_rename_and_git_configuration(self):
        names = ['a"quoted\tline\nfile.txt', "目录/é.txt", "literal\\file.txt", ":(glob)*.txt"]
        for name in names:
            self.write(name, "base\n")
        self.write("binary.bin", b"\0\x01\x02")
        self.write("source.txt", "rename contents\n")
        self.write("deleted.txt", "removed\n")
        self.write("mode.sh", "mode only\n")
        self.commit_fixture()
        for name in names:
            self.write(name, "diff --git a/fake b/fake\nnew\r\n")
        self.write("binary.bin", b"\0\x03\x04")
        self.git("mv", "source.txt", 'renamed "file.txt')
        self.write('renamed "file.txt', "changed after staging rename\n")
        (self.repo / "deleted.txt").unlink()
        (self.repo / "mode.sh").chmod(0o755)
        self.git("config", "diff.noprefix", "true")
        self.git("config", "diff.mnemonicPrefix", "true")
        self.git("config", "core.quotePath", "false")
        order = Path(self.build.name) / "order"
        order.write_text("binary.bin\nmode.sh\n*\n")
        self.git("config", "diff.orderFile", str(order))
        entries = self.fingerprints()
        for path, entry in entries.items():
            for layer in ("staged", "worktree"):
                key = layer + "Fingerprint"
                if key in entry:
                    original = [entry["original"]] if layer == "staged" and "original" in entry else []
                    digest = self.probe("fingerprint", path, layer, "false", *original)
                    self.assertEqual(entry[key], digest["fingerprint"], (path, layer))
        self.assertIn("stagedFingerprint", entries['renamed "file.txt'])
        self.assertIn("worktreeFingerprint", entries['renamed "file.txt'])
        binary = entries["binary.bin"]["worktreeFingerprint"]
        self.write("binary.bin", b"\0\x03\x05")
        self.assertNotEqual(binary, self.fingerprints()["binary.bin"]["worktreeFingerprint"])
        mode = entries["mode.sh"]["worktreeFingerprint"]
        self.write("mode.sh", "mode and content\n")
        self.assertNotEqual(mode, self.fingerprints()["mode.sh"]["worktreeFingerprint"])
        self.assertTrue(self.probe("malformed")["rejected"])

    def test_untracked_binary_symlink_permissions_and_ignored_paths(self):
        self.write(".gitignore", "ignored.txt\n")
        self.commit_fixture()
        self.write("untracked.bin", b"\0\x01\x02")
        self.write("ignored.txt", "ignored\n")
        self.write("intent.txt", "intent to add\n")
        self.git("add", "-N", "intent.txt")
        os.symlink("missing-target", self.repo / "link")
        initial = self.fingerprints()
        self.assertNotIn("ignored.txt", initial)
        for path in ("untracked.bin", "link", "intent.txt"):
            single = self.probe("fingerprint", path, "worktree", "true")
            self.assertEqual(single["commands"], 0)
            self.assertEqual(initial[path]["worktreeFingerprint"], single["fingerprint"])
        self.write("untracked.bin", b"\0\x01\x03")
        self.assertNotEqual(initial["untracked.bin"]["worktreeFingerprint"],
                            self.fingerprints()["untracked.bin"]["worktreeFingerprint"])
        (self.repo / "link").unlink()
        os.symlink("another-target", self.repo / "link")
        self.assertNotEqual(initial["link"]["worktreeFingerprint"],
                            self.fingerprints()["link"]["worktreeFingerprint"])
        self.git("config", "core.filemode", "false")
        previous = self.fingerprints()["untracked.bin"]["worktreeFingerprint"]
        (self.repo / "untracked.bin").chmod(0o755)
        executable = self.fingerprints()["untracked.bin"]["worktreeFingerprint"]
        self.assertNotEqual(previous, executable)
        (self.repo / "untracked.bin").chmod(0o654)
        self.assertEqual(previous, self.fingerprints()["untracked.bin"]["worktreeFingerprint"])
        self.write("large.bin", b"\0" * (5 * 1024 * 1024 + 1))
        self.assertNotIn("worktreeFingerprint", self.fingerprints()["large.bin"])

    def test_unborn_branch_has_independent_fingerprints_without_false_errors(self):
        self.write("initial.txt", "initial staged\n")
        self.git("add", "initial.txt")
        self.write("initial.txt", "initial worktree\n")
        self.write("untracked.txt", "draft\n")
        snapshot = self.probe()
        self.assertFalse(snapshot["hasHead"])
        self.assertEqual(snapshot["commits"], 0)
        self.assertNotIn("error", snapshot)
        entries = {entry["path"]: entry for entry in snapshot["entries"]}
        self.assertIn("stagedFingerprint", entries["initial.txt"])
        self.assertIn("worktreeFingerprint", entries["initial.txt"])
        self.assertIn("worktreeFingerprint", entries["untracked.txt"])

    def test_each_failed_detail_preserves_applied_and_cached_data(self):
        self.write("fixture.txt", "fixture\n")
        self.commit_fixture()
        self.write("fixture.txt", "stash\n")
        self.git("stash", "push", "-qm", "fixture stash")
        for command, detail in (("for-each-ref", "branches"), ("remote", "remotes"),
                                ("log", "history"), ("worktree", "worktrees"),
                                ("symbolic-ref", "defaultBranch"), ("rev-list", "stash")):
            with self.subTest(command=command):
                result = self.probe("failure", command)
                self.assertNotIn(detail, result["details"])
                self.assertEqual(result["appliedBranches"], ["feature-fixture", "main"])
                self.assertEqual(result["appliedRemotes"], ["origin"])
                self.assertEqual(result["appliedCommits"], 1)
                self.assertEqual(result["appliedWorktrees"], 1)
                self.assertEqual(result["appliedDefaultBranch"], "main")
                self.assertEqual(result["appliedStashCount"], 1)
                self.assertTrue(result["cacheRestored"])
                self.assertEqual(result["error"], "fixture detail timeout")

    def test_invalid_utf8_status_cannot_borrow_another_files_review(self):
        # APFS rejects invalid UTF-8 names, so exercise runGit's decoding result.
        self.assertTrue(self.probe("invalidUTF8")["rejected"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
