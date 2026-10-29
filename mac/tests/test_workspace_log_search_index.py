"""Exercise the workspace log scanner without starting the application."""
from pathlib import Path
import subprocess
import tempfile
import unittest

MAC = Path(__file__).resolve().parents[1]


class WorkspaceLogSearchIndexTests(unittest.TestCase):
    def test_unicode_duplicates_limits_and_cancellation(self):
        with tempfile.TemporaryDirectory(prefix="zshell-log-index-") as directory:
            source = Path(directory) / "Probe.swift"
            binary = Path(directory) / "probe"
            source.write_text(r'''
import Foundation

@main struct Probe {
    static func main() {
        let result = WorkspaceLogSearchIndex.search(
            text: "first NEE DLE\n中文 needle Café e\u{301} needle\nneedle", query: "needle", limit: 2)
        precondition(result.total == 3 && result.matches.count == 2)
        precondition(result.matches.map(\.occurrence) == [0, 1])
        precondition(result.matches[0].snippet.contains("中文 needle Café e\u{301}"))
        let folded = WorkspaceLogSearchIndex.search(text: "aAaA", query: "AA", limit: 5)
        precondition(folded.total == 2 && folded.matches.map(\.occurrence) == [0, 1])
        let unicode = WorkspaceLogSearchIndex.search(text: "é e\u{301} é", query: "é", limit: 5)
        precondition(unicode.total == 2)
        let clipped = WorkspaceLogSearchIndex.search(text: String(repeating: "文", count: 80) + "hit", query: "hit", limit: 1)
        precondition(!clipped.matches[0].snippet.contains("\u{fffd}"))
        let cancelled = WorkspaceLogSearchIndex.search(text: "needle", query: "needle", limit: 1, isCancelled: { true })
        precondition(cancelled.cancelled && cancelled.matches.isEmpty)
    }
}
''')
            subprocess.run(["swiftc", "-parse-as-library", str(MAC / "zshell/WorkspaceLogSearchIndex.swift"),
                            str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
