"""Exercise production settings search with live localization and no app services."""

import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unicodedata
import unittest
import uuid


REPO = Path(__file__).resolve().parents[2]
LANGUAGES = (
    "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR",
    "it", "nl", "ru", "ar", "th", "id", "vi", "tr",
)
CATEGORIES = (
    "general", "shortcuts", "appearance", "terminal", "editor", "browser", "automation",
    "recommendations", "updates",
)
CONFIGURATION_ITEMS = {
    "app-presence": ("general", "Show Zshell in", ""),
    "browser.content-blocking": ("browser", "Block ads and trackers", ""),
    "browser.filter-lists": ("browser", "Filter Lists", "Filter Lists"),
    "toolbar.visibility": ("general", "Toolbar", ""),
    "git.proxy-enabled": ("general", "Use proxy for Git", "Git"),
    "git.proxy": ("general", "Proxy address", "Git"),
    "git.pull-request-status": ("general", "Show pull request status", "Git"),
    "app-icon": ("appearance", "Dock icon", "App Icon"),
    "theme-dark": ("appearance", "Dark theme", "Colors"),
    "theme-light": ("appearance", "Light theme", "Colors"),
    "terminal.theme-only": ("appearance", "Terminal theme only", "Colors"),
    "font-family": ("appearance", "Latin family", "Font"),
    "terminal.font-fallback-family": ("appearance", "CJK fallback", "Font"),
    "font-size": ("appearance", "Size", "Font"),
    "terminal.line-height": ("appearance", "Line height", "Font"),
    "terminal.font-thicken": ("appearance", "Thicken font strokes", "Font"),
    "terminal.font-thicken-strength": ("appearance", "Stroke strength", "Font"),
    "interface.scale": ("appearance", "Interface size", "Interface"),
    "sidebar.font-size": ("appearance", "Font size", "Interface"),
    "panes.show-focus-ring": ("appearance", "Show focus ring on active pane", "Panes"),
    "panes.focus-ring-opacity": ("appearance", "Opacity", "Panes"),
    "terminal.startup-program": ("terminal", "Startup", ""),
    "terminal.startup-arguments": ("terminal", "Startup", ""),
    "terminal.backend": ("terminal", "Backend", ""),
    "terminal.cursor-shape": ("appearance", "Cursor shape", "Cursor"),
    "terminal.cursor-blinking": ("appearance", "Blink cursor", "Cursor"),
    "terminal.background-opacity": ("appearance", "Opacity", "Background"),
    "terminal.background-blur": ("appearance", "Blur behind window", "Background"),
    "terminal.auto-profiles": ("terminal", "Apply terminal profiles automatically", "Terminal Profiles"),
    "terminal.text-hints": ("terminal", "Show terminal text hints", "Input"),
    "terminal.shell-completions": ("terminal", "Shell completions", "Input"),
    "terminal.vim-command-hints": ("terminal", "Vim command hints", "Input"),
    "terminal.macos-option-as-alt": ("terminal", "Use Option as Alt/Meta", "Input"),
    "terminal.bell": ("terminal", "Terminal bell", "Notifications"),
    "terminal.shift-enter-newline": ("terminal", "Shift+Enter inserts a newline", "Input"),
    "terminal.command-history": ("terminal", "Record command history", "History"),
    "terminal.restore-history": ("terminal", "Restore session history on relaunch", "History"),
    "terminal.preserve-sessions": ("terminal", "Keep sessions running after quitting", ""),
    "terminal.copy-on-select": ("terminal", "Copy on select", "Input"),
    "terminal.focus-follows-mouse": ("terminal", "Focus follows mouse", "Input"),
    "terminal.notify-finish-seconds": ("terminal", "Long-running commands", "Notifications"),
    "terminal.notify-on-error": ("terminal", "Failed commands", "Notifications"),
    "quick-terminal.enabled": ("terminal", "Enable Quick Terminal", "Quick Terminal"),
    "quick-terminal.shortcut": ("terminal", "Shortcut", "Quick Terminal"),
    "quick-terminal.mode": ("terminal", "Session behavior", "Quick Terminal"),
    "quick-terminal.size": ("terminal", "Size", "Quick Terminal"),
    "quick-terminal.opacity": ("terminal", "Opacity", "Quick Terminal"),
    "editor.external-editor": ("editor", "External editor", ""),
    "editor.wrap-lines": ("editor", "Wrap lines to editor width", ""),
    "ai.enabled": ("automation", "AI", ""),
    "ai.resume-conversations": ("automation", "Resume agent conversations", ""),
    "ai.notify-on-attention": ("automation", "Notify when agents need attention", "Notifications"),
    "ai.notify-on-completion": ("automation", "Notify when agents finish", "Notifications"),
}
DESCRIPTION_ITEMS = {
    "Applies to Git panel actions, pull request status, and Git in terminals opened afterwards.":
        ("general", "Use proxy for Git", "Git"),
    "HTTP, HTTPS, or SOCKS proxy URL. Changes apply to terminals opened afterwards.":
        ("general", "Proxy address", "Git"),
    "Keep the window, sidebars, and editor on Zshell’s default colors":
        ("appearance", "Terminal theme only", "Colors"),
    "Changes apply only to new terminals. Open terminals keep their current process.":
        ("terminal", "Startup", ""),
    "Reopened terminals show their previous scrollback above a fresh shell":
        ("terminal", "Restore session history on relaunch", "History"),
    "Changes apply to new zsh terminals.": ("terminal", "Long-running commands", "Notifications"),
    "Lets agents delegate work and coordinate across Zshell panes": ("automation", "AI", ""),
    "Install Homebrew, then click Refresh to enable one-click installation.":
        ("recommendations", "Homebrew", "Manage Tools"),
    "Tools are downloaded, installed, and updated through your Homebrew installation.":
        ("recommendations", "Homebrew", "Manage Tools"),
    "Downloads updates in the background. If automatic installation is off, updates install when you quit Zshell.":
        ("updates", "Automatically download updates", ""),
    "Installs downloaded updates and restarts Zshell automatically. Running terminal processes will stop.":
        ("updates", "Automatically install updates", ""),
}
ACTION_ITEMS = (
    ("browser", "Import Browser Data…", ""),
    ("browser", "Imported Browser History", ""),
    ("terminal", "Workspace Templates…", ""),
    ("terminal", "Manage Terminal Profiles…", "Terminal Profiles"),
    ("terminal", "Command History…", "History"),
    ("terminal", "Notification History…", "Notifications"),
    ("automation", "Agent Conversation History", ""),
)

HARNESS = r'''
import AppKit
import Combine

@MainActor final class AppSettings {
    static let shared = AppSettings()
    var aiEnabled = true
    var quickTerminalEnabled = true
    var fontThicken = true
    var showPaneFocusRing = true
    var gitProxyEnabled = true
    var browserContentBlocking = true
    var terminalBackgroundOpacity = 0.85
}

@MainActor final class Updater {
    static let shared = Updater()
    var automaticallyChecksForUpdates = true
    var allowsAutomaticUpdates = true
    var automaticallyDownloadsUpdates = true
}

struct SearchInput: Decodable {
    let language: String
    let queries: [String]
    let disabled: [String]?
    let backgroundOpacity: Double?
    let reduceTransparency: Bool?
    let recommendations: RecommendationsInput?
}

struct RecommendationsInput: Decodable {
    let homebrewAvailable: Bool
    let hasMissingTools: Bool
    let hasUpdatableTools: Bool
}

@main
struct SearchHarness {
    @MainActor static func main() throws {
        let input = try JSONDecoder().decode(
            [SearchInput].self, from: FileHandle.standardInput.readDataToEndOfFile()
        )
        let domain = Bundle.main.bundleIdentifier!
        let before = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let globalBefore = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        var recommendationChanges: [[[String: String]]] = []
        let observation = SettingsVisibility.recommendationsDidChange.sink {
            recommendationChanges.append(SettingsSearchIndex.results(for: "Manage Tools").map { result in
                ["category": result.category.rawValue, "title": result.title, "section": result.section ?? ""]
            })
        }
        let samples: [[String: Any]] = input.map { sample in
            AppLocalization.apply(AppLanguage(rawValue: sample.language)!)
            let disabled = Set(sample.disabled ?? [])
            let settings = AppSettings.shared
            settings.aiEnabled = !disabled.contains("aiEnabled")
            settings.quickTerminalEnabled = !disabled.contains("quickTerminalEnabled")
            settings.fontThicken = !disabled.contains("fontThicken")
            settings.showPaneFocusRing = !disabled.contains("showPaneFocusRing")
            settings.gitProxyEnabled = !disabled.contains("gitProxyEnabled")
            settings.browserContentBlocking = !disabled.contains("browserContentBlocking")
            settings.terminalBackgroundOpacity = sample.backgroundOpacity ?? 0.85
            let updater = Updater.shared
            updater.automaticallyChecksForUpdates = !disabled.contains("automaticallyChecksForUpdates")
            updater.allowsAutomaticUpdates = !disabled.contains("allowsAutomaticUpdates")
            updater.automaticallyDownloadsUpdates = !disabled.contains("automaticallyDownloadsUpdates")
            let recommendations = sample.recommendations
            SettingsVisibility.updateRecommendations(.init(
                homebrewAvailable: recommendations?.homebrewAvailable ?? false,
                hasMissingTools: recommendations?.hasMissingTools ?? false,
                hasUpdatableTools: recommendations?.hasUpdatableTools ?? false
            ))
            var visibility = SettingsVisibility.current
            visibility.reduceTransparency = sample.reduceTransparency ?? false
            return [
                "language": AppLocalization.current.identifier,
                "queries": sample.queries.map { query in
                    SettingsSearchIndex.results(for: query, visibility: visibility).map { result in
                        ["category": result.category.rawValue, "title": result.title,
                         "section": result.section ?? "", "searchText": result.searchText]
                    }
                },
            ]
        }
        let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let globalAfter = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let output: [String: Any] = [
            "samples": samples,
            "preferencesUnchanged": NSDictionary(dictionary: before) == NSDictionary(dictionary: after)
                && NSDictionary(dictionary: globalBefore) == NSDictionary(dictionary: globalAfter),
            "recommendationChanges": recommendationChanges,
        ]
        withExtendedLifetime(observation) {}
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
'''


def metadata_enum(source, name, stop_before):
    # Keep the real cases and translated metadata while excluding GUI constructors.
    match = re.search(rf"^enum {name}\b.*?^}}", source, re.MULTILINE | re.DOTALL)
    if match is None or stop_before not in match[0]:
        raise AssertionError(f"could not extract {name} metadata")
    return match[0].split(stop_before, 1)[0] + "\n}\n"


class SettingsSearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="zshell-settings-search-test-",
            dir=os.environ.get("ZSHELL_SETTINGS_SEARCH_TEST_ROOT"),
        )
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        contents = root / "SearchProbe.app/Contents"
        resources = contents / "Resources"
        resources.mkdir(parents=True)
        cls.binary = contents / "MacOS/SearchProbe"
        cls.binary.parent.mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "sh.zshell.settings-search-test." + uuid.uuid4().hex,
            "CFBundleExecutable": cls.binary.name,
            "CFBundleDevelopmentRegion": "en",
            "CFBundlePackageType": "APPL",
        }))
        sources = REPO / "mac/zshell"
        catalog = sources / "Localizable.xcstrings"
        cls.strings = json.loads(catalog.read_text())["strings"]
        subprocess.run([
            "xcrun", "xcstringstool", "compile", str(catalog),
            "--output-directory", str(resources),
        ], check=True, capture_output=True, text=True)
        for language in LANGUAGES:
            if not (resources / f"{language}.lproj").is_dir():
                raise AssertionError(f"missing compiled {language} resources")
        metadata = root / "SearchMetadata.swift"
        metadata.write_text("import Foundation\n" + "\n".join([
            metadata_enum((sources / "Settings/SettingsWindowController.swift").read_text(),
                          "SettingsCategory", "    func makePane()"),
            metadata_enum((sources / "Theme.swift").read_text(), "AppTheme", "    var nsAppearance:"),
            metadata_enum((sources / "CommandShortcuts.swift").read_text(),
                          "AppCommand", "    var defaultShortcut:"),
            metadata_enum((sources / "TerminalBackend.swift").read_text(),
                          "TerminalBackend", "    var settingsHighlights:"),
            metadata_enum((sources / "ApplicationPresenceController.swift").read_text(),
                          "ApplicationPresence", "\n}"),
        ]))
        harness = root / "Harness.swift"
        harness.write_text(HARNESS)
        subprocess.run([
            "swiftc", "-parse-as-library", "-module-cache-path", str(root / "modules"),
            str(sources / "AppLocalization.swift"), str(sources / "RecommendedTool.swift"),
            str(sources / "Settings/SettingsSearch.swift"),
            str(sources / "Settings/SettingsVisibility.swift"), str(metadata), str(harness),
            "-o", str(cls.binary),
        ], check=True, capture_output=True, text=True)

    def translated(self, key, language):
        if not key or key == "Homebrew" or language == "en":
            return key
        return self.strings[key]["localizations"][language]["stringUnit"]["value"]

    def evaluate_output(self, samples):
        result = subprocess.run(
            [str(self.binary)], input=json.dumps(samples), text=True,
            capture_output=True, check=True,
        )
        output = json.loads(result.stdout)
        self.assertTrue(output["preferencesUnchanged"])
        return output

    def evaluate(self, samples):
        return self.evaluate_output(samples)["samples"]

    def query(self, queries, language="en"):
        sample = self.evaluate([{"language": language, "queries": queries}])[0]
        self.assertEqual(sample["language"], language)
        return sample["queries"]

    def assert_item(self, results, expected, language="en"):
        category, title, section = expected
        target = (category, self.translated(title, language), self.translated(section, language))
        self.assertIn(target, [(row["category"], row["title"], row["section"]) for row in results])

    def test_configuration_keys(self):
        queries = list(CONFIGURATION_ITEMS)
        for query, rows in zip(queries, self.query(queries)):
            with self.subTest(query=query):
                self.assert_item(rows, CONFIGURATION_ITEMS[query])

    def test_visible_descriptions(self):
        queries = list(DESCRIPTION_ITEMS)
        for query, rows in zip(queries, self.query(queries)):
            with self.subTest(query=query):
                self.assert_item(rows, DESCRIPTION_ITEMS[query])

    def test_multiple_terms_are_required_in_the_same_setting(self):
        queries = ["terminal background opacity", "Opacity Quick Terminal", "quick-terminal.size opacity",
                   "font-size Quick Terminal", "startup __missing_setting__",
                   "\tTeRMiNaL\n Background\t oPaCiTY "]
        results = self.query(queries)
        self.assertEqual(len(results[0]), 1)
        self.assert_item(results[0], ("appearance", "Opacity", "Background"))
        self.assertEqual(len(results[1]), 1)
        self.assert_item(results[1], ("terminal", "Opacity", "Quick Terminal"))
        for rows in results[2:5]:
            self.assertEqual(rows, [])
        self.assertEqual(results[0], results[5])

    def test_case_and_diacritic_folding(self):
        queries = ["Cursor shape", "CuRsOr ShApE", "Français", "FRANCAIS", "Opacity", "ÖPACITY"]
        results = self.query(queries)
        for original, folded in zip(results[::2], results[1::2]):
            self.assertTrue(original)
            self.assertEqual(original, folded)
        self.assert_item(results[2], ("general", "Language", ""))
        title = self.translated("External editor", "fr")
        folded = "".join(char for char in unicodedata.normalize("NFD", title)
                         if not unicodedata.combining(char))
        original, normalized = self.query([title, folded], "fr")
        self.assertTrue(original)
        self.assertEqual(original, normalized)

    def test_empty_and_unmatched_queries(self):
        for rows in self.query(["", " ", "\n\t ", "__no_such_setting__", "  __no_such_setting__  "]):
            self.assertEqual(rows, [])

    def test_conditional_usage_status_is_not_offered_as_a_setting(self):
        self.assertEqual(self.query(["Account Usage"]), [[]])

    def test_dependent_controls_follow_live_visibility_changes(self):
        cases = [
            ({"disabled": ["aiEnabled"]}, ["ai.resume-conversations", "ai.notify-on-attention", "ai.notify-on-completion"]),
            ({"disabled": ["quickTerminalEnabled"]}, ["quick-terminal.shortcut", "quick-terminal.mode", "quick-terminal.size", "quick-terminal.opacity"]),
            ({"disabled": ["fontThicken"]}, ["terminal.font-thicken-strength"]),
            ({"disabled": ["showPaneFocusRing"]}, ["panes.focus-ring-opacity"]),
            ({"disabled": ["gitProxyEnabled"]}, ["git.proxy"]),
            ({"disabled": ["browserContentBlocking"]}, ["browser.filter-lists"]),
            ({"disabled": ["automaticallyChecksForUpdates"]}, ["Automatically download updates", "Automatically install updates"]),
            ({"disabled": ["allowsAutomaticUpdates"]}, ["Automatically download updates", "Automatically install updates"]),
            ({"disabled": ["automaticallyDownloadsUpdates"]}, ["Automatically install updates"]),
            ({"backgroundOpacity": 1}, ["terminal.background-blur"]),
            ({"reduceTransparency": True}, ["terminal.background-blur"]),
        ]
        for state, queries in cases:
            sample = {"language": "en", "queries": queries}
            before, hidden, restored = self.evaluate([sample, {**sample, **state}, sample])
            with self.subTest(state=state):
                for query, visible_rows, hidden_rows in zip(queries, before["queries"], hidden["queries"]):
                    target = CONFIGURATION_ITEMS.get(query, ("updates", query, ""))
                    self.assert_item(visible_rows, target)
                    self.assertNotIn(target, [
                        (row["category"], row["title"], row["section"]) for row in hidden_rows
                    ])
                self.assertEqual(before, restored)

    def test_repeated_titles_keep_their_destination_groups(self):
        size, opacity, ai = self.query(["Size", "Opacity", "ai.enabled"])
        self.assertEqual({(row["category"], row["section"]) for row in size if row["title"] == "Size"},
                         {("appearance", "Font"), ("terminal", "Quick Terminal")})
        self.assertEqual({(row["category"], row["section"]) for row in opacity if row["title"] == "Opacity"},
                         {("appearance", "Panes"), ("appearance", "Background"), ("terminal", "Quick Terminal")})
        self.assertEqual(len(ai), 1)
        self.assert_item(ai, ("automation", "AI", ""))

    def test_recommended_actions_follow_available_tools(self):
        queries = ["Install Missing", "Update All", "Homebrew", "Refresh", "ripgrep"]
        states = [
            None,
            {"homebrewAvailable": False, "hasMissingTools": True, "hasUpdatableTools": True},
            {"homebrewAvailable": True, "hasMissingTools": False, "hasUpdatableTools": False},
            {"homebrewAvailable": True, "hasMissingTools": True, "hasUpdatableTools": False},
            {"homebrewAvailable": True, "hasMissingTools": False, "hasUpdatableTools": True},
            {"homebrewAvailable": True, "hasMissingTools": True, "hasUpdatableTools": True},
            None,
        ]
        samples = self.evaluate([{"language": "en", "queries": queries, "recommendations": state}
                                 for state in states])
        for state, sample in zip(states, samples):
            available = bool(state and state["homebrewAvailable"])
            for index, (key, title) in enumerate([
                ("hasMissingTools", "Install Missing"), ("hasUpdatableTools", "Update All"),
            ]):
                with self.subTest(state=state, title=title):
                    if available and state[key]:
                        self.assert_item(sample["queries"][index], ("recommendations", title, "Manage Tools"))
                    else:
                        self.assertNotIn(("recommendations", title, "Manage Tools"), [
                            (row["category"], row["title"], row["section"])
                            for row in sample["queries"][index]
                        ])
            self.assert_item(sample["queries"][2], ("recommendations", "Homebrew", "Manage Tools"))
            self.assert_item(sample["queries"][3], ("recommendations", "Refresh", "Manage Tools"))
            self.assertTrue(any(row["category"] == "recommendations" and row["title"] == "ripgrep"
                                for row in sample["queries"][4]))
        self.assertEqual(samples[0], samples[-1])

    def test_recommended_snapshot_notifies_after_changes_only(self):
        empty = {"homebrewAvailable": True, "hasMissingTools": False, "hasUpdatableTools": False}
        missing = {**empty, "hasMissingTools": True}
        both = {**missing, "hasUpdatableTools": True}
        states = [None, empty, empty, missing, missing, both, None]
        output = self.evaluate_output([{"language": "en", "queries": [], "recommendations": state}
                                       for state in states])
        actions = [{row["title"] for row in rows} & {"Install Missing", "Update All"}
                   for rows in output["recommendationChanges"]]
        self.assertEqual(actions, [set(), {"Install Missing"}, {"Install Missing", "Update All"}, set()])

    def test_recommended_actions_follow_live_language_changes(self):
        state = {"homebrewAvailable": True, "hasMissingTools": True, "hasUpdatableTools": True}
        samples = self.evaluate([{
            "language": language, "recommendations": state,
            "queries": [self.translated(title, language) for title in ("Install Missing", "Update All")],
        } for language in LANGUAGES])
        for language, sample in zip(LANGUAGES, samples):
            for title, rows in zip(("Install Missing", "Update All"), sample["queries"]):
                with self.subTest(language=language, title=title):
                    self.assert_item(rows, ("recommendations", title, "Manage Tools"), language)

    def test_unique_result_ids_in_every_language(self):
        samples = self.evaluate([{"language": language, "queries": list(CATEGORIES)}
                                 for language in LANGUAGES])
        for language, sample in zip(LANGUAGES, samples):
            self.assertEqual(sample["language"], language)
            for category, rows in zip(CATEGORIES, sample["queries"]):
                with self.subTest(language=language, category=category):
                    self.assertTrue(rows)
                    ids = [(row["category"], row["section"], row["title"]) for row in rows]
                    self.assertEqual(len(ids), len(set(ids)))

    def test_names_descriptions_and_keys_follow_live_language_changes(self):
        languages = LANGUAGES + ("zh-Hans", "en")
        items = list(dict.fromkeys(list(CONFIGURATION_ITEMS.values()) + list(ACTION_ITEMS)))
        samples = self.evaluate([{
            "language": language,
            "queries": [self.translated(item[1], language) for item in items]
                + [self.translated(description, language) for description in DESCRIPTION_ITEMS]
                + list(CONFIGURATION_ITEMS),
        } for language in languages])
        for language, sample in zip(languages, samples):
            self.assertEqual(sample["language"], language)
            expected = items + list(DESCRIPTION_ITEMS.values()) + list(CONFIGURATION_ITEMS.values())
            for destination, rows in zip(expected, sample["queries"]):
                with self.subTest(language=language, destination=destination):
                    self.assert_item(rows, destination, language)
        self.assertEqual(self.translated("Language", "zh-Hans"), "语言")
        self.assertEqual(self.translated("Language", "en"), "Language")


if __name__ == "__main__":
    unittest.main()
