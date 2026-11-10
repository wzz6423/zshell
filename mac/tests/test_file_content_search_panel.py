"""Exercise the production AppKit content-search table without visible windows.

Run: python3 mac/tests/test_file_content_search_panel.py
Run with the production editor: ZSHELL_TEST_DERIVED_DATA=/tmp/derived python3 mac/tests/test_file_content_search_panel.py
"""
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import unittest
import uuid

MAC = Path(__file__).resolve().parents[1]
BUILT_APP = "--built-app" in sys.argv or bool(os.environ.get("ZSHELL_TEST_DERIVED_DATA"))
if "--built-app" in sys.argv:
    sys.argv.remove("--built-app")


class FileContentSearchPanelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-search-panel-test-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        temporary = Path(cls.build.name)
        cls.helper = temporary / "panel-tests"
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                   "-default-isolation", "MainActor", "-module-cache-path", str(temporary / "modules")]
        if BUILT_APP:
            build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", MAC / "build/debug")) / "Build"
            products = build / "Products/Debug"
            app = products / "zshell Debug.app"
            library = app / "Contents/MacOS/zshell.debug.dylib"
            if not library.is_file():
                raise RuntimeError(f"Build the Debug app in {build.parent} before using --built-app")
            bundle = temporary / "Search Panel Probe.app/Contents"
            cls.helper = bundle / "MacOS/probe"
            cls.helper.parent.mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": f"sh.zshell.test.search-panel.{uuid.uuid4().hex}",
                "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
                "CFBundleDevelopmentRegion": "en", "LSBackgroundOnly": True,
            }))
            (bundle / "Resources").symlink_to(app / "Contents/Resources")
            command += ["-D", "ZSHELL_BUILT_APP", "-target", f"{platform.machine()}-apple-macos15.6",
                        "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
            for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
                command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
            for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                            "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
                path = MAC / "Vendor" / include
                command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
            command += ["-I", str(MAC / "Vendor/alacritty-bridge/include"),
                        "-I", str(MAC / "Vendor/tree-sitter/lib/include"), str(library),
                        "-Xlinker", "-rpath", "-Xlinker", str(products),
                        "-Xlinker", "-rpath", "-Xlinker", str(library.parent)]
        else:
            command += [str(MAC / "zshell/FileContentSearchModel.swift"),
                        str(MAC / "zshell/FileContentSearchView.swift"),
                        str(MAC / "zshell/MainActorIsolation.swift")]
        command += [str(MAC / "tests/FileContentSearchPanelTests.swift"),
                    str(MAC / "tests/QuickTerminalOffscreen.swift"), "-o", str(cls.helper)]
        subprocess.run(command, cwd=MAC.parent, check=True)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="zshell-search-panel-fixture-", dir="/tmp")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        (self.root / "empty").mkdir()
        home = self.root / "home"
        configuration = home / ".config/zshell-dev/config.toml"
        configuration.parent.mkdir(parents=True)
        (home / "tmp").mkdir()
        configuration.write_text("ai.enabled = false\nquick-terminal.enabled = false\n")
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("ZSHELL_") and key != "DYLD_INSERT_LIBRARIES"}
        self.environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                                TMPDIR=str(home / "tmp"), XDG_CONFIG_HOME=str(home / ".config"))

    def probe(self, mode, query="needle", replacement=None):
        args = [str(self.helper), mode, str(self.root), query]
        if replacement is not None:
            args.append(replacement)
        completed = subprocess.run(args, env=self.environment, cwd=self.root,
                                   text=True, capture_output=True, check=True, timeout=12)
        result = json.loads(completed.stdout)
        self.assertFalse(result["failed"], "grep failed")
        self.assertTrue(result["offscreenSafe"], "test process became visible or active")
        self.assertFalse(result["windowVisible"])
        return result

    def assert_rows(self, result, expected):
        self.assertEqual(result["matches"], expected)
        self.assertEqual(result["rows"], len(expected), "model matches did not become table rows")
        self.assertEqual(result["cells"], [[f"{hit['path']}:{hit['line']}", hit["content"]] for hit in expected],
                         "table delegate did not render the matched path and content")

    def write_matches(self):
        path = self.root / "nested/路径:component.txt"
        path.parent.mkdir()
        text = "é😀\r\nneedle first\nneedle second\n最後"
        path.write_text(text)
        expected = [{"path": "nested/路径:component.txt", "line": line, "content": content}
                    for line, content in [(2, "needle first"), (3, "needle second")]]
        return path, text, expected

    def test_streamed_matches_render_relative_paths_and_contents(self):
        _, _, expected = self.write_matches()
        self.assert_rows(self.probe("snapshot"), expected)

    def test_remount_renders_matches_that_already_exist(self):
        _, _, expected = self.write_matches()
        self.assert_rows(self.probe("remount"), expected)

    def test_observed_search_replacement_and_root_change_clear_stale_rows(self):
        (self.root / "result.txt").write_text("old\nnew\nold\n")
        result = self.probe("refresh", "old", "new")
        self.assert_rows(result, [{"path": "result.txt", "line": line, "content": "old"} for line in (1, 3)])
        self.assert_rows(result["replacement"], [{"path": "result.txt", "line": 2, "content": "new"}])
        self.assert_rows(result["empty"], [])
        self.assert_rows(result["rerooted"], [])

    def assert_actions(self, result, expected):
        self.assert_rows(result, expected)
        self.assertEqual(result["selectionOnlyOpenCount"], 0)
        self.assertEqual(result["returnOpenCount"], 1)
        self.assertEqual(result["unselectedReturnOpenCount"], 1)
        self.assertEqual(result["clickedRow"], 0)
        self.assertEqual(result["opened"], [expected[1], expected[0]])

    def test_return_and_single_click_open_the_selected_result(self):
        _, _, expected = self.write_matches()
        self.assert_actions(self.probe("actions"), expected)

    @unittest.skipUnless(BUILT_APP, "Use --built-app or ZSHELL_TEST_DERIVED_DATA for the production editor")
    def test_return_and_click_reveal_the_matched_unicode_line_in_the_editor(self):
        path, text, expected = self.write_matches()
        result = self.probe("editor")
        self.assert_actions(result, expected)
        self.assertEqual(len(result["editors"]), 2)
        for editor, line, offset in zip(result["editors"], (3, 2), (18, 5)):
            self.assertEqual(editor["path"], str(path))
            self.assertEqual(editor["line"], line)
            self.assertEqual(editor["location"], offset)
            self.assertEqual(editor["selection"], offset)
            self.assertEqual(editor["selectionLength"], 0)
            self.assertEqual(editor["text"], text)
            self.assertTrue(editor["hasEditor"])
            self.assertFalse(editor["windowVisible"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
