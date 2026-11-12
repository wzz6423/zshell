"""Exercise Git status refreshes and review fingerprints in disposable repositories.

Run: python3 -B mac/tests/test_git_status_snapshot.py
Production Swift slices, binaries, and module caches stay in a temporary folder.
"""
from pathlib import Path
import json
import os
import random
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
        state += slice_between(model, "    /// Branches checked out by a worktree", "    /// Absolute repository root.")
        state += '    private var topLevel = ""\n'
        # The sliced parser reads this cap while it walks every NUL record.
        state += slice_between(
            model,
            "    private nonisolated static let maximumRetainedCommitFiles = 200\n",
            "    private var recentCommitLimit",
        )
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
        let commitLimit = action == "history" ? Int(CommandLine.arguments[3])! : 30
        var commands = 0
        var historyOutput = ""
        let start = Date()
        func snapshot(failing failedCommand: String? = nil) -> GitStatusModel.StatusResult {
            let load = GitStatusModel.runGitStatus(in: root, recentCommitLimit: commitLimit, commandRunner: { arguments, directory, timeout in
                commands += 1
                if arguments.first == failedCommand {
                    return (-2, "", "fixture detail timeout")
                }
                let result = GitStatusModel.runGit(arguments, in: directory, timeout: timeout)
                if arguments.first == "log" { historyOutput = result.stdout }
                return result
            }, reviewCommandRunner: { arguments, directory, timeout in
                commands += 1
                return GitCommandRunner.runData(arguments, in: directory, limit: .max, timeout: timeout)
            })
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
                "hasMoreCommits": snapshot.hasMoreRecentCommits,
                "history": snapshot.recentCommits.map { commit -> [String: Any] in
                    var value: [String: Any] = ["hash": commit.hash, "shortHash": commit.shortHash,
                        "subject": commit.subject, "author": commit.author,
                        "timestamp": commit.date.timeIntervalSince1970,
                        "references": commit.references,
                        "files": commit.files.map { file -> [String: Any] in
                            var value: [String: Any] = ["path": file.path, "status": String(file.status)]
                            value["original"] = file.originalPath
                            return value
                        }]
                    value["omittedFileCount"] = commit.omittedFileCount
                    value["parent"] = commit.parentHash
                    return value
                },
                "worktrees": snapshot.worktrees.count, "stashCount": snapshot.stashCount,
                "details": snapshot.loadedDetails.map { String(describing: $0) }.sorted(),
                "commands": commands, "elapsed": Date().timeIntervalSince(start)]
            value["error"] = snapshot.detailError
            value["branch"] = snapshot.branch
            value["defaultBranch"] = snapshot.defaultBranch
            return value
        }
        var output: [String: Any]
        if action == "snapshot" || action == "history" {
            output = asJSON(snapshot())
        } else if action == "historyOutput" {
            output = asJSON(snapshot())
            output["historyOutput"] = historyOutput
        } else if action == "parseHistory" {
            let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            var parsed = GitStatusModel.StatusResult()
            parsed.recentCommits = GitStatusModel.parseRecentCommits(String(decoding: raw, as: UTF8.self))
            output = asJSON(parsed)
        } else if action == "branches" {
            let current = snapshot()
            let model = GitStatusModel()
            model.applyRepository(current)
            output = asJSON(current)
            output["availableBranches"] = model.branchesWithoutWorktrees
        } else if action == "fingerprint" {
            let path = CommandLine.arguments[3]
            let layer: DiffReviewLayer = CommandLine.arguments[4] == "staged" ? .staged : .worktree
            let untracked = CommandLine.arguments[5] == "true"
            let original = CommandLine.arguments.count > 6 ? CommandLine.arguments[6] : nil
            let hasHead = GitStatusModel.runGit(["rev-parse", "--verify", "HEAD"], in: root).status == 0
            let digest = DiffReviewFingerprint.load(path: path, originalPath: original, layer: layer,
                hasHead: hasHead, untracked: untracked, in: root) { args, directory in
                    commands += 1
                    return GitCommandRunner.runData(args, in: directory, limit: .max)
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
        } else if action == "mixedReview" {
            let model = GitStatusModel()
            model.applyRepository(snapshot())
            let layer = CommandLine.arguments[3] == "staged"
            let entries = layer ? model.stagedEntries : model.changedEntries
            let normal = entries.first { $0.path == "normal.txt" }!.reviewSnapshot(staged: layer)!
            DiffReviewStore.shared.setReviewed(true, for: normal)
            let latinURL = URL(fileURLWithPath: root).appendingPathComponent("latin1.txt")
            try (Data("modified latin".utf8) + Data([0xe9, 10])).write(to: latinURL)
            if layer {
                precondition(GitStatusModel.runGit(["add", "latin1.txt"], in: root).status == 0)
            }
            model.applyRepository(snapshot())
            let mixed = layer ? model.stagedEntries : model.changedEntries
            let latinBefore = mixed.first { $0.path == "latin1.txt" }!.reviewSnapshot(staged: layer)!
            precondition(DiffReviewStore.shared.isReviewed(normal), "another file's encoding erased a review")
            DiffReviewStore.shared.setReviewed(true, for: latinBefore)
            try (Data("modified latin".utf8) + Data([0xe8, 10])).write(to: latinURL)
            if layer {
                precondition(GitStatusModel.runGit(["add", "latin1.txt"], in: root).status == 0)
            }
            model.applyRepository(snapshot())
            let after = layer ? model.stagedEntries : model.changedEntries
            let latinAfter = after.first { $0.path == "latin1.txt" }!.reviewSnapshot(staged: layer)!
            precondition(latinBefore.fingerprint != latinAfter.fingerprint, "different invalid bytes collided")
            precondition(!DiffReviewStore.shared.isReviewed(latinBefore))
            precondition(DiffReviewStore.shared.isReviewed(normal))
            let run = GitCommandRunner.runData(["--literal-pathspecs", "diff", "--binary", "--full-index",
                "--no-abbrev", "--no-renames", "--no-color", "--no-ext-diff", "--no-textconv",
                "--src-prefix=a/", "--dst-prefix=b/"] + (layer ? ["--cached", "HEAD"] : []) + ["--", "normal.txt"],
                in: root, limit: .max)
            precondition(run.status == 0)
            let text = String(data: run.stdout, encoding: .utf8)!
            precondition(DiffReviewSnapshot.fingerprint(path: "normal.txt", payload: text) == normal.fingerprint,
                "valid UTF-8 fingerprints changed")
            output = ["normalReviewPreserved": true, "distinctByteFingerprints": true, "utf8Stable": true]
        } else if action == "renameBatch" {
            let paths = CommandLine.arguments.dropFirst(3).map { String($0) }
            let original = paths.first!
            let destination = paths.last!
            var batchCalls = 0
            var sawOriginal = false
            var sawDestination = false
            let patches = DiffReviewFingerprint.trackedPatches(for: paths, layer: .staged, hasHead: true,
                in: root, runGit: { arguments, directory in
                    batchCalls += 1
                    let boundary = arguments.firstIndex(of: "--")!
                    let batch = arguments[arguments.index(after: boundary)...]
                    if batch.contains(original) { sawOriginal = true; precondition(!batch.contains(destination)) }
                    if batch.contains(destination) { sawDestination = true; precondition(!batch.contains(original)) }
                    return GitCommandRunner.runData(arguments, in: directory, limit: .max)
                })!
            precondition(batchCalls > 1 && sawOriginal && sawDestination)
            precondition(patches[original] != nil && patches[destination] != nil)
            let fingerprint = DiffReviewFingerprint.fingerprint(path: destination, originalPath: original, patches: patches)!
            let single = DiffReviewFingerprint.load(path: destination, originalPath: original,
                layer: .staged, hasHead: true, untracked: false, in: root,
                runGit: { GitCommandRunner.runData($0, in: $1, limit: .max) })
            precondition(fingerprint == single)
            for truncated in [false, true] {
                let partial = DiffReviewFingerprint.trackedPatches(for: paths, layer: .staged, hasHead: true,
                    in: root, runGit: { arguments, directory in
                        let boundary = arguments.firstIndex(of: "--")!
                        if arguments[arguments.index(after: boundary)...].contains(destination) {
                            let output = GitCommandRunner.runData(arguments, in: directory, limit: .max)
                            return GitCommandDataResult(status: truncated ? 0 : -2, stdout: output.stdout,
                                stderr: "fixture batch failure", truncated: truncated)
                        }
                        return GitCommandRunner.runData(arguments, in: directory, limit: .max)
                    })
                precondition(partial == nil, "a failed rename batch returned only its deletion half")
            }
            output = ["completeRename": true, "partialBatchesRejected": true, "batchCalls": batchCalls]
        } else if action == "malformed" {
            let outputWithExtraSection = ":100644 100644 abc 000 M\0one.txt\0\0diff --git a/one.txt b/one.txt\n+text\ndiff --git a/two.txt b/two.txt\n"
            let parsed = DiffReviewFingerprint.trackedPatches(for: ["one.txt"], layer: .worktree, hasHead: true,
                in: root, runGit: { _, _ in
                    GitCommandDataResult(status: 0, stdout: Data(outputWithExtraSection.utf8), stderr: "", truncated: false)
                })
            precondition(parsed == nil, "malformed patch sections were accepted")
            output = ["rejected": true]
        } else if action == "invalidUTF8" {
            let bytes = Data("# branch.oid abc\0# branch.head main\0? invalid-".utf8) + Data([0xff, 0])
            let decoded = String(data: bytes, encoding: .utf8) ?? ""
            let result = GitStatusModel.runGitStatus(in: root, recentCommitLimit: 30, commandRunner: { arguments, _, _ in
                arguments.first == "rev-parse" ? (0, root + "\n", "") : (0, decoded, "")
            })
            guard case .failed = result else { fatalError("An undecodable status was accepted") }
            let patches = DiffReviewFingerprint.trackedPatches(for: ["safe.txt"], layer: .worktree,
                hasHead: true, in: root, runGit: { _, _ in
                    let raw = Data(":100644 100644 abc 000 M\0invalid-".utf8) + Data([0xff, 0, 0])
                    return GitCommandDataResult(status: 0, stdout: raw, stderr: "", truncated: false)
                })
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

    def parse_history(self, raw):
        with tempfile.TemporaryDirectory(prefix="zshell-history-wire-") as temporary:
            fixture = Path(temporary) / "history.bin"
            fixture.write_bytes(raw)
            return self.probe("parseHistory", str(fixture))

    def history_wire(self, commits):
        """NUL log in the shape parseRecentCommits expects."""
        chunks = []
        for commit in commits:
            chunks.extend(field.encode() for field in (
                commit["hash"], commit["short"], commit["subject"], commit["author"],
                str(commit["timestamp"]), commit.get("parent", ""), commit.get("refs", ""),
            ))
            for index, record in enumerate(commit["files"]):
                status = record[0].encode()
                if index == 0:
                    status = b"\n" + status
                chunks.append(status)
                chunks.extend(path.encode() for path in record[1:])
            chunks.append(b"")
        return b"\0".join(chunks)

    def test_history_keeps_control_characters_in_paths_subjects_and_authors(self):
        original_path = "before\x1eafter.txt"
        self.write(original_path, "root\n")
        self.git("add", ".")
        self.git("commit", "-qm", "root fixture")
        root_hash = self.git("rev-parse", "HEAD").decode().strip()

        author = "History\x1eAuthor\x1fName"
        subject = "subject\x1fwith\x1econtrols"
        self.git("config", "user.name", author)
        self.write("next.txt", "next\n")
        self.git("add", ".")
        self.git("commit", "-q", "--cleanup=verbatim", "-m", subject)
        latest_hash = self.git("rev-parse", "HEAD").decode().strip()

        snapshot = self.probe()
        self.assertEqual(snapshot["commits"], 2)
        latest, root = snapshot["history"]
        self.assertEqual(latest["hash"], latest_hash)
        self.assertEqual(latest["subject"], subject)
        self.assertEqual(latest["author"], author)
        self.assertEqual(latest["parent"], root_hash)
        self.assertEqual(latest["files"], [{"status": "A", "path": "next.txt"}])
        self.assertEqual(root["hash"], root_hash)
        self.assertNotIn("parent", root)
        self.assertEqual(root["files"], [{"status": "A", "path": original_path}])
        self.assertNotIn("error", snapshot)

    def test_history_keeps_empty_root_and_merge_commits_between_file_changes(self):
        self.git("commit", "-q", "--allow-empty", "--allow-empty-message", "-m", "")
        root_hash = self.git("rev-parse", "HEAD").decode().strip()
        self.git("commit", "-q", "--allow-empty", "-m", "empty child")
        empty_hash = self.git("rev-parse", "HEAD").decode().strip()
        self.git("switch", "-qc", "topic")
        self.write("topic.txt", "topic\n")
        self.git("add", ".")
        self.git("commit", "-qm", "topic")
        topic_hash = self.git("rev-parse", "HEAD").decode().strip()
        self.git("switch", "main")
        self.write("main.txt", "main\n")
        self.git("add", ".")
        self.git("commit", "-qm", "main")
        main_hash = self.git("rev-parse", "HEAD").decode().strip()
        self.git("merge", "-q", "--no-ff", "-m", "merged topic", "topic")
        merge_hash = self.git("rev-parse", "HEAD").decode().strip()
        self.git("tag", "merged-fixture")

        snapshot = self.probe()
        history = {commit["hash"]: commit for commit in snapshot["history"]}
        self.assertEqual(set(history), {root_hash, empty_hash, main_hash, topic_hash, merge_hash})
        self.assertEqual(history[root_hash]["subject"], "")
        self.assertNotIn("parent", history[root_hash])
        self.assertEqual(history[root_hash]["files"], [])
        self.assertEqual(history[empty_hash]["parent"], root_hash)
        self.assertEqual(history[empty_hash]["files"], [])
        self.assertEqual(history[main_hash]["files"], [{"status": "A", "path": "main.txt"}])
        self.assertEqual(history[topic_hash]["files"], [{"status": "A", "path": "topic.txt"}])
        self.assertEqual(snapshot["history"][0]["hash"], merge_hash)
        self.assertEqual(history[merge_hash]["parent"], main_hash)
        self.assertEqual(history[merge_hash]["files"], [])
        self.assertEqual(history[merge_hash]["references"], ["HEAD -> main", "tag: merged-fixture"])
        self.assertFalse(snapshot["hasMoreCommits"])
        self.assertNotIn("error", snapshot)

    def test_history_rename_and_copy_consume_both_literal_paths(self):
        original = "before\x1eoriginal\n.txt"
        renamed = "R100\x1frenamed\n.txt"
        copied = "\nC100\x1ecopied.txt"
        content = "copy baseline\n" * 20
        self.write(original, content)
        self.git("add", ".")
        self.git("commit", "-qm", "root")
        self.git("mv", "--", original, renamed)
        self.git("commit", "-qm", "rename")
        rename_hash = self.git("rev-parse", "HEAD").decode().strip()
        self.git("config", "diff.renames", "copies")
        self.write(copied, content)
        self.write(renamed, "changed original\n" * 20)
        self.git("add", ".")
        self.git("commit", "-qm", "copy")

        snapshot = self.probe()
        copy, rename, root = snapshot["history"]
        self.assertEqual(rename["hash"], rename_hash)
        self.assertEqual(rename["files"], [{"status": "R", "path": renamed, "original": original}])
        self.assertEqual({file["path"]: file for file in copy["files"]}, {
            copied: {"status": "C", "path": copied, "original": renamed},
            renamed: {"status": "M", "path": renamed},
        })
        self.assertEqual(root["files"], [{"status": "A", "path": original}])
        self.assertNotIn("error", snapshot)

    def test_history_pagination_survives_controls_at_the_page_boundary(self):
        hashes = []
        for index in range(34):
            self.write("page.txt", f"page {index}\n")
            self.git("add", ".")
            self.git("commit", "-q", "--cleanup=verbatim", "-m", f"commit\x1e{index}\x1f")
            hashes.insert(0, self.git("rev-parse", "HEAD").decode().strip())

        for limit in (1, 30, 34, 60):
            with self.subTest(limit=limit):
                snapshot = self.probe("history", str(limit))
                self.assertEqual([commit["hash"] for commit in snapshot["history"]], hashes[:limit])
                self.assertEqual(snapshot["hasMoreCommits"], limit < len(hashes))
                self.assertEqual([commit["subject"] for commit in snapshot["history"]],
                                 [f"commit\x1e{index}\x1f" for index in range(33, max(-1, 33 - limit), -1)])
                self.assertNotIn("error", snapshot)

    def test_history_fixed_seed_paths_cannot_spoof_statuses_or_headers(self):
        clean = self.probe()
        randomizer = random.Random(6423)
        characters = "abcXYZ09 \t\n\r\\\"\x01\x1e\x1f中文"
        paths = ["A", "R100", "C100", "\nA", "\x1e" + "a" * 40 + "\x1fheader.txt",
                 "--name-status", "$(touch escaped).txt", "`touch escaped`.txt"]
        paths += [f"path-{index:02}-" + "".join(randomizer.choice(characters) for _ in range(20))
                  for index in range(64)]
        for path in paths:
            self.write(path, "literal file\n")
        self.git("add", ".")
        self.git("commit", "-qm", "special paths")

        snapshot = self.probe()
        self.assertEqual(snapshot["commits"], 1)
        self.assertEqual({file["path"]: file["status"] for file in snapshot["history"][0]["files"]},
                         {path: "A" for path in paths})
        self.assertLessEqual(snapshot["commands"], clean["commands"])
        self.assertFalse((self.repo / "escaped").exists())
        self.assertNotIn("error", snapshot)

    def test_history_ignores_signature_diagnostics_in_user_git_configuration(self):
        with tempfile.TemporaryDirectory(prefix="zshell-history-signing-") as temporary:
            key = Path(temporary) / "signing"
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                           check=True, capture_output=True)
            self.git("config", "gpg.format", "ssh")
            self.git("config", "user.signingKey", str(key))
            self.git("config", "log.showSignature", "true")
            self.git("commit", "-q", "--allow-empty", "-S", "-m", "signed fixture")
            expected_hash = self.git("rev-parse", "HEAD").decode().strip()
            snapshot = self.probe()
            self.assertEqual(snapshot["commits"], 1)
            self.assertEqual(snapshot["history"][0]["hash"], expected_hash)
            self.assertEqual(snapshot["history"][0]["subject"], "signed fixture")
            self.assertEqual(snapshot["history"][0]["files"], [])
            self.assertNotIn("error", snapshot)

    def test_history_truncation_returns_only_complete_metadata_and_paths(self):
        original = "original\x1e.txt"
        destination = "destination\x1f.txt"
        self.write(original, "root\n")
        self.git("add", ".")
        self.git("commit", "-qm", "root")
        self.git("mv", "--", original, destination)
        self.git("commit", "-qm", "rename")
        snapshot = self.probe("historyOutput")
        raw = snapshot["historyOutput"].encode()
        complete = snapshot["history"]
        boundaries = {0, len(raw)}
        for index, byte in enumerate(raw):
            if byte == 0:
                boundaries.update((index, index + 1))
        for boundary in sorted(boundaries):
            with self.subTest(boundary=boundary):
                parsed = self.parse_history(raw[:boundary])["history"]
                self.assertLessEqual(len(parsed), len(complete))
                for actual, expected in zip(parsed, complete):
                    # A complete header at EOF is indistinguishable from an
                    # empty commit, but no returned path may be partial.
                    self.assertEqual({key: value for key, value in actual.items() if key != "files"},
                                     {key: value for key, value in expected.items() if key != "files"})
                    self.assertEqual(actual["files"], expected["files"][:len(actual["files"])])

        fields = raw.split(b"\0")
        for invalid_status in (b"Q", b"A\x1eheader", b"R100\nA", b"Cunknown"):
            with self.subTest(status=invalid_status):
                corrupt = list(fields)
                corrupt[7] = invalid_status
                self.assertEqual(self.parse_history(b"\0".join(corrupt))["history"], [])

    def test_history_parser_scales_with_large_nul_delimited_output(self):
        for index in range(100):
            self.write(f"large-{index:03}\x1e\x1f\n.txt", "large history\n")
        self.git("add", ".")
        self.git("commit", "-qm", "large history")
        raw = self.probe("historyOutput")["historyOutput"].encode() + b"\0"
        timings = []
        for count in (20, 80):
            parsed = self.parse_history(raw * count)
            self.assertEqual(len(parsed["history"]), count)
            self.assertEqual(sum(len(commit["files"]) for commit in parsed["history"]), 100 * count)
            self.assertEqual(parsed["commands"], 0)
            timings.append(parsed["elapsed"])
            self.assertLess(parsed["elapsed"], 2)
        self.assertLess(timings[1], max(0.1, timings[0] * 7))
        print(f"History parser 2,000/8,000 paths: {timings[0]:.4f}s / {timings[1]:.4f}s")

    def test_history_retains_at_most_200_files_and_keeps_the_next_commit(self):
        # The extra record is a rename. Missing either of its paths would make
        # the following commit unreadable, and the omitted path must not be invented.
        oversized_files = [("A", f"file-{index:04}.txt") for index in range(200)]
        oversized_files.append(("R100", "old-name.txt", "new-name.txt"))
        oversized_hash = "a" * 40
        follow_hash = "b" * 40
        parsed = self.parse_history(self.history_wire([
            {"hash": oversized_hash, "short": "aaaaaaa", "subject": "oversized",
             "author": "Snapshot Tests", "timestamp": 1700000000, "files": oversized_files},
            {"hash": follow_hash, "short": "bbbbbbb", "subject": "small follow-up",
             "author": "Snapshot Tests", "timestamp": 1700000100, "parent": oversized_hash,
             "refs": "HEAD -> main", "files": [("M", "kept.txt")]},
        ]))["history"]
        self.assertEqual(len(parsed), 2)
        oversized, follow_up = parsed
        self.assertEqual(oversized["hash"], oversized_hash)
        self.assertEqual(oversized["subject"], "oversized")
        self.assertEqual(len(oversized["files"]), 200)
        self.assertEqual(oversized["omittedFileCount"], 1)
        self.assertEqual([item["path"] for item in oversized["files"]],
                         [f"file-{index:04}.txt" for index in range(200)])
        self.assertTrue(all(item["status"] == "A" and "original" not in item
                            for item in oversized["files"]))
        omitted_paths = {"old-name.txt", "new-name.txt"}
        self.assertTrue(omitted_paths.isdisjoint(item["path"] for item in oversized["files"]))
        self.assertEqual(follow_up["hash"], follow_hash)
        self.assertEqual(follow_up["shortHash"], "bbbbbbb")
        self.assertEqual(follow_up["subject"], "small follow-up")
        self.assertEqual(follow_up["author"], "Snapshot Tests")
        self.assertEqual(follow_up["parent"], oversized_hash)
        self.assertEqual(follow_up["references"], ["HEAD -> main"])
        self.assertEqual(follow_up["files"], [{"status": "M", "path": "kept.txt"}])
        self.assertEqual(follow_up["omittedFileCount"], 0)

        exact_hash = "c" * 40
        after_hash = "d" * 40
        exact = self.parse_history(self.history_wire([
            {"hash": exact_hash, "short": "ccccccc", "subject": "exact bound",
             "author": "Snapshot Tests", "timestamp": 1700000200,
             "files": [("A", f"exact-{index:04}.txt") for index in range(200)]},
            {"hash": after_hash, "short": "ddddddd", "subject": "after exact",
             "author": "Snapshot Tests", "timestamp": 1700000300, "parent": exact_hash,
             "files": [("A", "after.txt")]},
        ]))["history"]
        self.assertEqual(len(exact), 2)
        self.assertEqual(len(exact[0]["files"]), 200)
        self.assertEqual(exact[0]["omittedFileCount"], 0)
        self.assertEqual([item["path"] for item in exact[0]["files"]],
                         [f"exact-{index:04}.txt" for index in range(200)])
        self.assertEqual(exact[1]["hash"], after_hash)
        self.assertEqual(exact[1]["subject"], "after exact")
        self.assertEqual(exact[1]["parent"], exact_hash)
        self.assertEqual(exact[1]["files"], [{"status": "A", "path": "after.txt"}])
        self.assertEqual(exact[1]["omittedFileCount"], 0)

    def test_branch_names_survive_tag_collisions_and_worktree_filtering(self):
        self.write("fixture.txt", "fixture\n")
        self.commit_fixture()
        self.git("branch", "heads/feature")
        worktree = self.repo.parent / (self.repo.name + "-worktree")
        self.addCleanup(lambda: self.git("worktree", "remove", "--", str(worktree)))
        self.git("worktree", "add", "-q", "--", str(worktree), "feature-fixture")
        for name in ("main", "feature-fixture", "heads/feature", "origin/main"):
            self.git("tag", name)

        snapshot = self.probe("branches")
        self.assertEqual(snapshot["branch"], "main")
        self.assertEqual(snapshot["branches"], ["feature-fixture", "heads/feature", "main"])
        self.assertEqual(snapshot["availableBranches"], ["heads/feature"])
        self.assertEqual(snapshot["defaultBranch"], "main")
        self.assertNotIn("error", snapshot)

        self.git("switch", "heads/feature")
        switched = self.probe("branches")
        self.assertEqual(switched["branch"], "heads/feature")
        self.assertEqual(switched["availableBranches"], ["main"])
        self.assertEqual(switched["defaultBranch"], "main")

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
                self.write("file-299.txt", b"changed Latin1 caf\xe9\n")
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

    def test_mixed_utf8_and_latin1_patches_keep_other_files_reviewed(self):
        self.write("normal.txt", "base normal\n")
        self.write("latin1.txt", b"base caf\xe9\n")
        self.commit_fixture()
        self.write("normal.txt", "edited normal\n")
        self.write("latin1.txt", b"edited caf\xe9\n")
        patch = self.git("diff", "--binary", "--", "normal.txt", "latin1.txt")
        self.assertIn(b"\xe9", patch)
        self.assertNotIn(b"GIT binary patch", patch)
        with self.assertRaises(UnicodeDecodeError):
            patch.decode("utf8")
        for layer in ("worktree", "staged"):
            if layer == "staged":
                self.git("add", ".")
            entries = self.fingerprints()
            for path in ("normal.txt", "latin1.txt"):
                digest = self.probe("fingerprint", path, layer, "false")
                self.assertEqual(entries[path][layer + "Fingerprint"], digest["fingerprint"])
            result = self.probe("mixedReview", layer)
            self.assertTrue(result["normalReviewPreserved"])
            self.assertTrue(result["distinctByteFingerprints"])
            self.assertTrue(result["utf8Stable"])

    def test_rename_across_batches_requires_complete_raw_byte_patches(self):
        original = "a-original.txt"
        destination = "z-destination.txt"
        self.write(original, b"rename caf\xe9\n")
        self.commit_fixture()
        self.git("mv", original, destination)
        self.write(destination, b"rename caf\xe8\n")
        self.git("add", destination)
        # Long literal pathspecs force the rename deletion and addition into
        # separate batches without creating hundreds of extra files.
        fillers = [f"m-{index:03}-" + "x" * 100 + ".txt" for index in range(350)]
        result = self.probe("renameBatch", original, *fillers, destination)
        self.assertTrue(result["completeRename"])
        self.assertTrue(result["partialBatchesRejected"])
        self.assertGreater(result["batchCalls"], 1)

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
