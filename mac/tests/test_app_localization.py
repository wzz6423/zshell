"""Exercise live language selection against the compiled production catalog."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class AppLocalizationTests(unittest.TestCase):
    def test_switch_languages_without_restarting(self):
        mac = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="zshell-language-test-") as temporary:
            root = Path(temporary)
            contents = root / "LanguageProbe.app/Contents"
            resources = contents / "Resources"
            resources.mkdir(parents=True)
            executable = contents / "MacOS/LanguageProbe"
            executable.parent.mkdir()
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "sh.zshell.language-test",
                "CFBundleExecutable": executable.name,
                "CFBundleDevelopmentRegion": "en",
                "CFBundlePackageType": "APPL",
            }))
            subprocess.run([
                "xcrun", "xcstringstool", "compile", str(mac / "zshell/Localizable.xcstrings"),
                "--output-directory", str(resources),
            ], check=True, capture_output=True)
            source = root / "Probe.swift"
            source.write_text(r'''
import Foundation

@main
struct Probe {
    @MainActor
    static func main() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let domain = Bundle.main.bundleIdentifier!
        let original = UserDefaults.standard.persistentDomain(forName: domain)
        let samples: [(AppLanguage, String, String)] = [
            (.english, "Language", "Save / save and quit"),
            (.simplifiedChinese, "语言", "保存／保存并退出"),
            (.japanese, "言語", "保存／保存して終了"),
            (.english, "Language", "Save / save and quit"),
        ]
        var commandKeys: Set<String>?
        for (language, title, save) in samples {
            AppLocalization.apply(language)
            precondition(String(localized: "Language") == title)
            let commands = VimCommandCatalog.ordered(for: .normal)
            precondition(commands.first?.command.explanation == save)
            precondition(VimCommandCatalog.ordered(for: .normal, query: save).first?.command.keys == ":w · :wq")
            let keys = Set(commands.map { $0.command.keys })
            if let commandKeys { precondition(commandKeys == keys) }
            commandKeys = keys
            let userContent = "Language / 语言 / 言語"
            let interpolated = String(localized: "Open \(userContent)")
            precondition(interpolated.contains(userContent))
            precondition(String(localized: "A missing translation") == "A missing translation")
            precondition(ProcessInfo.processInfo.processIdentifier == pid)
        }
        precondition(AppLocalization.resolve(.system, systemLanguages: ["zh-Hans-CN", "en-US"]).identifier == "zh-Hans")
        precondition(AppLocalization.resolve(.system, systemLanguages: ["fr-FR", "ja-JP"]).identifier == "ja")
        precondition(AppLocalization.resolve(.system, systemLanguages: ["en-GB"]).identifier == "en")
        precondition(AppLocalization.resolve(.english, systemLanguages: ["ja-JP"]).identifier == "en")
        AppLocalization.apply(.system)
        precondition(AppLocalization.current.identifier == AppLocalization.resolve(.system).identifier)
        let final = UserDefaults.standard.persistentDomain(forName: domain)
        precondition(NSDictionary(dictionary: original ?? [:]) == NSDictionary(dictionary: final ?? [:]))
        print("Live language selection, catalog refresh, interpolation, fallback, and system preference passed")
    }
}
''')
            subprocess.run([
                "swiftc", "-parse-as-library",
                str(mac / "zshell/AppLocalization.swift"),
                str(mac / "zshell/VimCommandHints.swift"), str(source), "-o", str(executable),
            ], check=True, text=True)
            result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
            self.assertIn("passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
