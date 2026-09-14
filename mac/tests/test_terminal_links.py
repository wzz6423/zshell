"""Exercise terminal link classification against real temporary file paths.

Run: python3 mac/tests/test_terminal_links.py
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "zshell/TerminalSession.swift"


class TerminalLinkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-link-test-")
        cls.addClassCleanup(cls.build.cleanup)
        source = SOURCE.read_text()
        classifier = source[
            source.index("    func terminalLinkTarget(for value:"):
            source.index("    func terminalDidScroll(")
        ]
        helper = Path(cls.build.name) / "main.swift"
        helper.write_text(
            "import Foundation\n"
            "enum TerminalLinkTarget { case file(URL), url(URL) }\n"
            "struct Session {\n"
            "var foregroundDirectoryPath: String? = nil\n"
            "let currentDirectoryPath: String\n"
            + classifier + "\n}\n"
            'let session = Session(currentDirectoryPath: CommandLine.arguments[1])\n'
            'let result: [String: String]\n'
            'switch session.terminalLinkTarget(for: CommandLine.arguments[2]) {\n'
            'case .file(let url): result = ["kind": "file", "value": url.path]\n'
            'case .url(let url): result = ["kind": "url", "value": url.absoluteString]\n'
            'case nil: result = ["kind": "none"]\n}\n'
            'print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))\n'
        )
        cls.helper = Path(cls.build.name) / "links"
        subprocess.run(["swiftc", str(helper), "-o", str(cls.helper)], check=True)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="zshell-link-fixture-")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)

    def classify(self, value):
        return json.loads(subprocess.check_output(
            [str(self.helper), str(self.root), value], text=True,
        ))

    def test_bare_hosts_with_ports_open_with_web_schemes(self):
        for value, expected in [
            ("localhost:3000", "http://localhost:3000"),
            ("example.com:8080/path", "https://example.com:8080/path"),
            ("localhost.example.com:3000", "https://localhost.example.com:3000"),
            ("www.example.com。", "https://www.example.com"),
        ]:
            with self.subTest(value=value):
                self.assertEqual(self.classify(value), {"kind": "url", "value": expected})

    def test_relative_diagnostic_location_resolves_to_file(self):
        path = self.root / "main.swift"
        path.write_text("let value = 1\n")
        self.assertEqual(self.classify("main.swift:12:3"), {
            "kind": "file", "value": str(path),
        })

    def test_literal_colon_path_takes_precedence(self):
        path = self.root / "name:12"
        path.write_text("fixture\n")
        self.assertEqual(self.classify("name:12"), {"kind": "file", "value": str(path)})

    def test_existing_schemes_and_plain_non_links(self):
        self.assertEqual(self.classify("https://example.com/a"), {
            "kind": "url", "value": "https://example.com/a",
        })
        self.assertEqual(self.classify("mailto:test@example.com"), {
            "kind": "url", "value": "mailto:test@example.com",
        })
        self.assertEqual(self.classify("config.yaml"), {"kind": "none"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
