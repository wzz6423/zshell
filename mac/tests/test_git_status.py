"""Exercise GitStatusModel's porcelain parser with a real duplicate-path repository.

Run: python3 mac/tests/test_git_status.py
Only the standard library, git, and swiftc are required.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "zshell/GitStatusModel.swift"
DUPLICATE_PATH = "duplicate status.txt"


class GitStatusParserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-git-status-test-")
        cls.addClassCleanup(cls.build.cleanup)
        source = SOURCE.read_text()
        entry = source[
            source.index("    nonisolated struct Entry: Identifiable"):
            source.index("    /// Compact Explorer-style decoration")
        ]
        result = source[
            source.index("    nonisolated struct StatusResult:"):
            source.index("    /// Runs Git while draining stdout")
        ]
        parser = source[
            source.index("    /// Parses NUL-delimited porcelain v2."):
            source.index("    nonisolated static func parseWorktrees(")
        ]
        helper = Path(cls.build.name) / "main.swift"
        helper.write_text(
            "import Foundation\n"
            "struct Worktree: Equatable, Sendable {}\n"
            "struct RecentCommit: Equatable, Sendable {}\n"
            "struct GitStatusModel {\n"
            + entry + result + parser
            + "}\n"
            + "let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))\n"
            + "let output = String(decoding: data, as: UTF8.self)\n"
            + "let entries = GitStatusModel.parseStatus(output).entries\n"
            + "precondition(entries.count == 1, \"duplicate path was not collapsed\")\n"
            + "let entry = entries[0]\n"
            + "precondition(entry.path == CommandLine.arguments[2], \"unexpected path\")\n"
            + "precondition(entry.staged == \"D\" && entry.unstaged == \".\", "
            + "\"first staged deletion did not win\")\n"
            + "let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.staged) })\n"
            + "precondition(byPath.count == 1, \"entries are not safe to key by path\")\n"
            + "print(\"Git status parser: 4 passed, 0 failed\")\n"
        )
        cls.helper = Path(cls.build.name) / "git-status-parser"
        subprocess.run(["swiftc", str(helper), "-o", str(cls.helper)], check=True)

    def test_staged_deletion_and_untracked_share_one_path(self):
        with tempfile.TemporaryDirectory(prefix="zshell-git-fixture-") as temp:
            repo = Path(temp)
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Regression Test")
            self.git(repo, "config", "user.email", "regression@example.invalid")
            (repo / DUPLICATE_PATH).write_text("tracked\n")
            self.git(repo, "add", "--", DUPLICATE_PATH)
            self.git(repo, "commit", "-qm", "fixture")
            self.git(repo, "rm", "--cached", "-q", "--", DUPLICATE_PATH)

            status = subprocess.check_output([
                "/usr/bin/git", "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignored=matching",
            ], cwd=repo)
            records = [record for record in status.split(b"\0") if record]
            path = DUPLICATE_PATH.encode()
            matching = [record for record in records if record.endswith(path)]
            self.assertEqual(len(matching), 2)
            self.assertTrue(matching[0].startswith(b"1 D."))
            self.assertEqual(matching[1], b"? " + path)

            status_file = repo / "status.bin"
            status_file.write_bytes(status)
            run = subprocess.run(
                [str(self.helper), str(status_file), DUPLICATE_PATH],
                check=True, capture_output=True, text=True,
            )
            self.assertIn("4 passed, 0 failed", run.stdout)

    @staticmethod
    def git(repo, *args):
        subprocess.run(["/usr/bin/git", *args], cwd=repo, check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
