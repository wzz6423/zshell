"""Exercise cursor configuration and its AppKit picker without building the app."""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]

HARNESS = r'''
import AppKit
import Foundation

struct CursorInput: Decodable {
    let configuration: String
}

@main
struct CursorHarness {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let input = try JSONDecoder().decode(
            CursorInput.self,
            from: FileHandle.standardInput.readDataToEndOfFile()
        )
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try input.configuration.write(to: url, atomically: true, encoding: .utf8)
        let toml = TOML.parse(at: url)!
        var settings = CursorSettingsFixture(toml)
        let initialized = settings.cursorShape.rawValue
        let atDefaults = settings.isAtDefaults
        let serialized = settings.serializedConfig()
        try serialized.write(to: url, atomically: true, encoding: .utf8)
        let roundTrip = CursorSettingsFixture(TOML.parse(at: url)!).cursorShape.rawValue
        var imported = CursorSettingsFixture([:])
        imported.applyImported(toml)
        let importedShape = imported.cursorShape.rawValue
        settings.resetToDefaults()

        let view = TerminalCursorShapeSettingsView(frame: .zero)
        let popup = view.subviews.compactMap { $0 as? NSPopUpButton }.first!
        let popupOrder = popup.itemArray.map { $0.representedObject as! String }
        let popupSelections = TerminalCursorShape.allCases.map { shape in
            view.apply(shape: shape)
            return popup.selectedItem!.representedObject as! String
        }
        let result: [String: Any] = [
            "initialized": initialized,
            "imported": importedShape,
            "atDefaults": atDefaults,
            "serialized": serialized,
            "roundTrip": roundTrip,
            "reset": settings.cursorShape.rawValue,
            "resetIsDefault": settings.isAtDefaults,
            "cases": TerminalCursorShape.allCases.map(\.rawValue),
            "ghostty": TerminalCursorShape.allCases.map { $0.ghosttyValue.rawValue },
            "alacritty": TerminalCursorShape.allCases.map { Int($0.alacrittyValue) },
            "popupOrder": popupOrder,
            "popupSelections": popupSelections,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
    }
}
'''


class TerminalCursorSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-cursor-test-")
        cls.addClassCleanup(cls.build.cleanup)
        directory = Path(cls.build.name)
        settings = (REPO / "mac/zshell/AppSettings.swift").read_text()
        reads = re.findall(
            r'cursorShape = TerminalCursorShape\(\s*'
            r'rawValue: toml\["terminal\.cursor-shape"\]\?\.string \?\? ""\s*'
            r'\) \?\? \.\w+',
            settings,
        )
        if len(reads) != 2:
            raise AssertionError("expected launch and import cursor readers")
        reset = re.search(r"^        cursorShape = \.\w+$", settings, re.MULTILINE).group()
        predicate = re.search(r"&& (cursorShape == \.\w+)", settings).group(1)
        writer = re.search(
            r"        if cursorShape != \.\w+ \{\n.*?\n        \}",
            settings,
            re.DOTALL,
        ).group()
        toml = settings[settings.index("enum TOML {"):]
        fixture = directory / "CursorSettingsFixture.swift"
        fixture.write_text(
            "import Foundation\n" + toml + "\n"
            "struct CursorSettingsFixture {\n"
            "    var cursorShape: TerminalCursorShape\n"
            "    init(_ toml: [String: TOML.Value]) {\n" + reads[0] + "\n    }\n"
            "    mutating func applyImported(_ toml: [String: TOML.Value]) {\n"
            + reads[1] + "\n    }\n"
            "    var isAtDefaults: Bool { " + predicate + " }\n"
            "    mutating func resetToDefaults() {\n" + reset + "\n    }\n"
            "    func serializedConfig() -> String {\n"
            "        var lines: [String] = []\n" + writer + "\n"
            + r'        return lines.joined(separator: "\n") + "\n"' + "\n"
            "    }\n}\n"
        )
        ghostty = (REPO / "mac/Vendor/libghostty-spm/Sources/GhosttyTerminal/"
                  "Configuration/TerminalConfiguration.swift").read_text()
        cursor_style = re.search(
            r"public enum TerminalCursorStyle:.*?\n\}", ghostty, re.DOTALL
        ).group()
        module = directory / "GhosttyTerminal.swift"
        module.write_text(cursor_style)
        module_object = directory / "GhosttyTerminal.o"
        module_cache = directory / "modules"
        subprocess.run([
            "swiftc", "-parse-as-library", "-emit-module", "-emit-object",
            "-module-name", "GhosttyTerminal", "-module-cache-path", str(module_cache),
            "-emit-module-path", str(directory / "GhosttyTerminal.swiftmodule"),
            str(module), "-o", str(module_object),
        ], check=True)
        harness = directory / "Harness.swift"
        harness.write_text(HARNESS)
        cls.binary = directory / "cursor-settings"
        cls.config = directory / "config.toml"
        subprocess.run([
            "swiftc", "-parse-as-library", "-module-cache-path", str(module_cache),
            "-I", str(directory), str(module_object), str(fixture), str(harness),
            str(REPO / "mac/zshell/TerminalCursorSettings.swift"),
            str(REPO / "mac/zshell/TerminalCursorSettingsView.swift"),
            "-o", str(cls.binary),
        ], check=True)

    def evaluate(self, configuration=""):
        result = subprocess.run(
            [str(self.binary), str(self.config)],
            input=json.dumps({"configuration": configuration}),
            text=True, capture_output=True, check=True,
        )
        return json.loads(result.stdout)

    def test_new_configuration_defaults_to_bar(self):
        result = self.evaluate()
        self.assertEqual(result["initialized"], "bar")
        self.assertTrue(result["atDefaults"])
        self.assertEqual(result["serialized"], "\n")
        self.assertEqual(result["roundTrip"], "bar")

    def test_missing_cursor_key_defaults_to_bar_on_launch_and_import(self):
        result = self.evaluate("font-size = 18\n")
        self.assertEqual(result["initialized"], "bar")
        self.assertEqual(result["imported"], "bar")

    def test_invalid_cursor_shapes_fall_back_to_bar(self):
        for value in ('"invalid"', '""', "true", "42"):
            with self.subTest(value=value):
                result = self.evaluate(f"terminal.cursor-shape = {value}\n")
                self.assertEqual(result["initialized"], "bar")
                self.assertEqual(result["imported"], "bar")

    def test_explicit_shapes_survive_launch_import_and_save(self):
        for shape in ("bar", "block", "underline"):
            with self.subTest(shape=shape):
                result = self.evaluate(f'terminal.cursor-shape = "{shape}"\n')
                self.assertEqual(result["initialized"], shape)
                self.assertEqual(result["imported"], shape)
                self.assertEqual(result["roundTrip"], shape)
                expected = "\n" if shape == "bar" else f'terminal.cursor-shape = "{shape}"\n'
                self.assertEqual(result["serialized"], expected)

    def test_table_style_cursor_configuration_is_preserved(self):
        for shape in ("block", "underline"):
            with self.subTest(shape=shape):
                result = self.evaluate(f'[terminal]\ncursor-shape = "{shape}"\n')
                self.assertEqual(result["initialized"], shape)
                self.assertEqual(result["imported"], shape)
                self.assertEqual(result["roundTrip"], shape)

    def test_all_cases_keep_raw_values_with_bar_first(self):
        self.assertEqual(self.evaluate()["cases"], ["bar", "block", "underline"])

    def test_backend_mappings_are_unchanged(self):
        result = self.evaluate()
        self.assertEqual(result["ghostty"], ["bar", "block", "underline"])
        self.assertEqual(result["alacritty"], [2, 0, 1])

    def test_appkit_picker_puts_bar_first_and_preserves_selection(self):
        result = self.evaluate()
        self.assertEqual(result["popupOrder"], ["bar", "block", "underline"])
        self.assertEqual(result["popupSelections"], ["bar", "block", "underline"])

    def test_reset_and_default_detection_use_bar(self):
        for shape in ("bar", "block", "underline"):
            with self.subTest(shape=shape):
                result = self.evaluate(f'terminal.cursor-shape = "{shape}"\n')
                self.assertEqual(result["atDefaults"], shape == "bar")
                self.assertEqual(result["reset"], "bar")
                self.assertTrue(result["resetIsDefault"])

    def test_configuration_docs_match_the_cursor_default_and_order(self):
        documents = sorted((REPO / "web/content/docs").glob("configuration*.mdx"))
        self.assertTrue(documents)
        for document in documents:
            with self.subTest(document=document.name):
                rows = [line for line in document.read_text().splitlines()
                        if line.startswith("| `terminal.cursor-shape` |")]
                self.assertEqual(len(rows), 1)
                columns = [column.strip() for column in rows[0].split("|")]
                self.assertEqual(columns[2], '`"bar"`')
                self.assertEqual(columns[3], '`"bar"` / `"block"` / `"underline"`')


if __name__ == "__main__":
    unittest.main()
