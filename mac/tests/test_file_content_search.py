"""Exercise the search model against macOS grep without opening app windows.

Run: python3 mac/tests/test_file_content_search.py
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

MAC = Path(__file__).resolve().parents[1]


class FileContentSearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-search-test-")
        cls.addClassCleanup(cls.build.cleanup)
        helper = Path(cls.build.name) / "SearchHarness.swift"
        helper.write_text(r'''
import Foundation

@main struct SearchHarness {
    @MainActor static func main() async throws {
        let model = FileContentSearchModel()
        model.sync(root: CommandLine.arguments[1])
        model.query = CommandLine.arguments[2]
        model.run()
        if CommandLine.arguments.count > 3 {
            model.query = CommandLine.arguments[3]
            model.run()
        }
        for _ in 0..<500 {
            if !model.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result: [String: Any] = [
            "running": model.isRunning,
            "truncated": model.isTruncated,
            "failed": model.failureMessage != nil,
            "matches": model.matches.map {
                ["path": $0.path, "line": $0.line, "content": $0.content] as [String: Any]
            },
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
''')
        cls.helper = Path(cls.build.name) / "search"
        subprocess.run([
            "swiftc", "-parse-as-library",
            str(MAC / "zshell/FileContentSearchModel.swift"),
            str(MAC / "zshell/MainActorIsolation.swift"),
            str(helper), "-o", str(cls.helper),
        ], check=True)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="zshell-search-fixture-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)

    def search(self, query="needle", replacement=None):
        args = [str(self.helper), str(self.root), query]
        if replacement is not None:
            args.append(replacement)
        result = json.loads(subprocess.check_output(args, text=True, timeout=8))
        self.assertFalse(result["running"], "grep did not complete")
        self.assertFalse(result["failed"], "grep failed")
        return result

    def test_file_names_keep_colons_and_newlines(self):
        names = ["plain.txt", "has:colon.txt", "has\nnewline.txt"]
        for name in names:
            (self.root / name).write_text("first\nneedle\n")
        result = self.search()
        self.assertEqual({hit["path"] for hit in result["matches"]}, set(names))
        self.assertTrue(all(hit["line"] == 2 for hit in result["matches"]))

    def test_fast_exit_keeps_every_pipe_chunk(self):
        (self.root / "many.txt").write_text("needle\n" * 1999)
        result = self.search()
        self.assertEqual(len(result["matches"]), 1999)
        self.assertEqual(result["matches"][-1]["line"], 1999)
        self.assertFalse(result["truncated"])

    def test_match_limit_finishes_with_exact_cap(self):
        (self.root / "many.txt").write_text("needle\n" * 5000)
        result = self.search()
        self.assertEqual(len(result["matches"]), 2000)
        self.assertTrue(result["truncated"])

    def test_replaced_search_cannot_publish_old_matches_or_limit(self):
        (self.root / "many.txt").write_text("old\n" * 5000 + "new\n")
        result = self.search("old", "new")
        self.assertEqual(result["matches"], [
            {"path": "many.txt", "line": 5001, "content": "new"},
        ])
        self.assertFalse(result["truncated"])

    def test_query_starting_with_dash_and_binary_exclusion(self):
        (self.root / "plain.txt").write_text("-needle\n")
        (self.root / "binary.bin").write_bytes(b"\0-needle\n")
        result = self.search("-needle")
        self.assertEqual([hit["path"] for hit in result["matches"]], ["plain.txt"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
