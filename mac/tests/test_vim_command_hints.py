"""Run the production Vim classifier against local and SSH screen fixtures.

Run: python3 mac/tests/test_vim_command_hints.py
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class VimCommandHintTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-vim-test-")
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name)
        main = directory / "main.swift"
        main.write_text(r'''
import Foundation
struct Input: Decodable {
    let executable: String
    let title: String
    let text: String
    let previouslyDetected: Bool
    let query: String
    let foregroundPID: Int32?
    let launchPID: Int32?
    let launchProcessGroup: Int32?
}
let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
let mode = VimModeDetection.detect(executable: input.executable, title: input.title,
                                  text: input.text, previouslyDetected: input.previouslyDetected)
let entries = VimCommandCatalog.ordered(for: mode ?? .normal, query: input.query)
let inspectionPID = input.foregroundPID.map {
    VimModeDetection.inspectionPID(foregroundPID: $0, launchPID: input.launchPID,
                                  launchProcessGroup: input.launchProcessGroup)
} ?? 0
let result = ["mode": mode?.rawValue ?? "none", "first": entries.first?.command.keys ?? "",
              "count": String(entries.count), "total": String(VimCommandCatalog.all.count),
              "inspectionPID": String(inspectionPID),
              "keys": entries.map { $0.command.keys }.joined(separator: "\n")]
let translated = VimCommandReference(command: .init("yy", "复制整行・行をコピー"), modes: [.normal])
precondition(translated.matches("复制") && translated.matches("コピー") && translated.matches("YY"))
precondition(!translated.matches("unknown"))
FileHandle.standardOutput.write(try JSONEncoder().encode(result))
''')
        cls.binary = directory / "vim-hints"
        source = Path(__file__).resolve().parents[1] / "zshell/VimCommandHints.swift"
        subprocess.run(["swiftc", str(source), str(main), "-o", str(cls.binary)], check=True)

    def detect(self, text, executable="vim", title="", previous=False, query="", process=None):
        result = subprocess.run([str(self.binary)], input=json.dumps({
            "executable": executable, "title": title, "text": text,
            "previouslyDetected": previous, "query": query,
            **(process or {}),
        }), text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_foreground_login_wrapper_and_background_jobs(self):
        cases = [
            (200, 201, 200, 201),
            (200, 201, 201, 200),
            (200, None, None, 200),
            (200, 0, 200, 200),
            (200, 201, -1, 200),
            (200, 200, 200, 200),
            (201, 200, 200, 201),
        ]
        for foreground, launch, group, expected in cases:
            with self.subTest(foreground=foreground, launch=launch, group=group):
                result = self.detect("", process={
                    "foregroundPID": foreground, "launchPID": launch,
                    "launchProcessGroup": group,
                })
                self.assertEqual(int(result["inspectionPID"]), expected)

    def test_mode_priority(self):
        cases = [
            ("~\n~\n", "normal", ":w · :wq"),
            ("~\n-- INSERT --", "insert", "Esc"),
            ("~\n-- INSERT (paste) --", "insert", "Esc"),
            ("~\n-- REPLACE --", "replace", "Esc"),
            ("~\n-- VISUAL --", "visual", "y · d · c"),
            ("~\n-- VISUAL LINE --", "visualLine", "y · d · c"),
            ("~\n-- VISUAL BLOCK --", "visualBlock", "I / A → text → Esc"),
            ("~\n-- SELECT --", "select", "Type"),
            ("~\n:w", "commandLine", ":w · :wq"),
            ("~\n/needle", "search", "Enter · Esc"),
            ("~\n?needle", "search", "Enter · Esc"),
        ]
        all_keys = sorted(self.detect("")["keys"].splitlines())
        for screen, mode, first in cases:
            with self.subTest(mode=mode):
                result = self.detect(screen)
                self.assertEqual((result["mode"], result["first"]), (mode, first))
                self.assertEqual(result["count"], result["total"])
                self.assertEqual(sorted(result["keys"].splitlines()), all_keys)
                self.assertGreater(int(result["total"]), 30)
                self.assertIn("yy · p / P", result["keys"])

    def test_search_keys_description_and_mode(self):
        self.assertEqual(self.detect("", query="yy")["keys"], "yy · p / P")
        self.assertIn("u · Ctrl-R", self.detect("", query="undo")["keys"])
        self.assertIn("I / A", self.detect("", query="visualBlock")["keys"])
        self.assertEqual(self.detect("", query="no-such-command")["count"], "0")
        self.assertEqual(self.detect("", query="  ")["count"], self.detect("")["total"])

    def test_translated_and_custom_status(self):
        cases = [
            ("-- 插入 --", "insert"), ("-- 可视 块 --", "visualBlock"),
            ("-- 挿入 --", "insert"), ("V-BLOCK test.swift  2:1", "visualBlock"),
            ("V-LINE test.swift  2:1", "visualLine"),
            ("INSERT test.swift  2:1\n", "insert"),
        ]
        for screen, mode in cases:
            with self.subTest(screen=screen):
                self.assertEqual(self.detect(screen)["mode"], mode)

    def test_remote_entry_and_exit(self):
        for executable in ["ssh", "mosh-client", "tmux"]:
            with self.subTest(executable=executable):
                self.assertEqual(self.detect('~\n~\n"test.md" [New]', executable)["mode"], "normal")
                self.assertEqual(self.detect("content\n-- VISUAL BLOCK --", executable)["mode"], "visualBlock")
                self.assertEqual(self.detect("content\n 12,1    All\n", executable)["mode"], "normal")
                self.assertEqual(self.detect("~\n~\n", executable, previous=True)["mode"], "normal")
                self.assertEqual(self.detect("user@server:~$ ", executable, title="file - VIM", previous=True)["mode"], "none")
                self.assertEqual(self.detect("Connection closed", executable, previous=True)["mode"], "none")

    def test_unrelated_process_and_editor_text_do_not_activate(self):
        self.assertEqual(self.detect("-- INSERT --", "zsh", title="vim test.md")["mode"], "none")
        self.assertEqual(self.detect("-- INSERT --", "nano")["mode"], "none")
        self.assertEqual(self.detect("user@server:~$ vim file", "ssh")["mode"], "none")
        self.assertEqual(self.detect("-- VISUAL BLOCK --\nexample\n\n", "ssh")["mode"], "none")
        self.assertEqual(self.detect("~\n~\nexample", "ssh")["mode"], "none")

    def test_local_neovim_and_return_to_normal(self):
        self.assertEqual(self.detect("text\n\n", "nvim", previous=True)["mode"], "normal")
        self.assertEqual(self.detect("text\n-- VISUAL --", "nvim")["mode"], "visual")
        self.assertEqual(self.detect("\n", "vi")["mode"], "normal")


if __name__ == "__main__":
    unittest.main()
