"""Exercise complete translations and live selection against production catalogs."""
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest
import uuid


LANGUAGES = (
    "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR",
    "it", "nl", "ru", "ar", "th", "id", "vi", "tr",
)

# These are names, format-only strings, or words shared by the target languages.
# Keeping an explicit list catches English fallback copied into a new entry.
SHARED_TEXT = {
    "%@ — %@", "%@%% · %@", "%@, %@", "%@: %@", "%@…", "+%lld, −%lld",
    "%lld fps", "%lld pt", "%lld sessions", "AI", "Agents", "Arguments", "Backend", "Block",
    "Browser", "Conflict", "Cursor", "Detached HEAD", "Editor", "File", "Font",
    "General", "Git", "Git (⇧⌘G)", "Help", "Host", "Info", "Info (⇧⌘I)",
    "Interface", "Name", "Normal", "OK", "Optional", "Options", "PORTS",
    "Password", "Port", "Program", "Services", "Session", "Sessions", "Status",
    "Stop", "System", "Tab", "Tab %lld", "Tab %lld, %@", "Tabs", "Terminal",
    "Type", "Updates", "Visual", "WORKTREES", "Zoom", "detached HEAD",
    "example.com", "worktree",
}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:\d+(?:\.\d+)?)?(?:ll|l)?[@difus]")


def placeholders(value):
    # A literal percent may follow an interpolation ("%lld% used"). It is not
    # a printf flag followed by the first letter of the translated next word.
    return Counter(
        re.sub(r"^%\d+\$", "%", token)
        for token in PLACEHOLDER.findall(value.replace("%%", ""))
    )


def string_units(localization):
    if "stringUnit" in localization:
        yield localization["stringUnit"]
    for variants in localization.get("variations", {}).values():
        for variant in variants.values():
            yield from string_units(variant)


class AppLocalizationTests(unittest.TestCase):
    def test_complete_catalogs_and_placeholders(self):
        mac = Path(__file__).resolve().parents[1]
        for catalog in (mac / "zshell").glob("*.xcstrings"):
            strings = json.loads(catalog.read_text())["strings"]
            for key, entry in strings.items():
                if entry.get("shouldTranslate") is False:
                    continue
                for language in LANGUAGES[1:]:
                    with self.subTest(catalog=catalog.name, key=key, language=language):
                        self.assertIn(language, entry.get("localizations", {}))
                        localized = entry["localizations"][language]
                        units = list(string_units(localized))
                        self.assertTrue(units)
                        for unit in units:
                            self.assertEqual(unit["state"], "translated")
                            self.assertTrue(unit["value"].strip())
                            self.assertEqual(placeholders(unit["value"]), placeholders(key))
                            if unit["value"] == key:
                                self.assertIn(key, SHARED_TEXT)
                        plural = localized.get("variations", {}).get("plural")
                        if plural:
                            required = {
                                "ar": {"zero", "one", "two", "few", "many", "other"},
                                "ru": {"one", "few", "many", "other"},
                            }.get(language, {"one", "other"})
                            self.assertTrue(required.issubset(plural))

        project = (mac / "zshell.xcodeproj/project.pbxproj").read_text()
        regions = re.search(r"knownRegions\s*=\s*\((.*?)\);", project, re.S).group(1)
        self.assertEqual(set(re.findall(r"[\w-]+", regions)) - {"Base"}, set(LANGUAGES))

    def test_switch_languages_without_restarting(self):
        mac = Path(__file__).resolve().parents[1]
        domain = "sh.zshell.language-test." + uuid.uuid4().hex
        with tempfile.TemporaryDirectory(prefix="zshell-language-test-", dir="/tmp") as temporary:
            root = Path(temporary)
            contents = root / "LanguageProbe.app/Contents"
            resources = contents / "Resources"
            resources.mkdir(parents=True)
            executable = contents / "MacOS/LanguageProbe"
            executable.parent.mkdir()
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": domain,
                "CFBundleExecutable": executable.name,
                "CFBundleDevelopmentRegion": "en",
                "CFBundlePackageType": "APPL",
            }))
            for catalog in (mac / "zshell").glob("*.xcstrings"):
                result = subprocess.run([
                    "xcrun", "xcstringstool", "compile", str(catalog),
                    "--output-directory", str(resources),
                ], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            for language in LANGUAGES:
                self.assertTrue((resources / f"{language}.lproj").is_dir(), language)
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
        let globalLanguages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        defer {
            if let original { UserDefaults.standard.setPersistentDomain(original, forName: domain) }
            else { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        precondition(AppLanguage.allCases.count == 18)
        precondition(AppLanguage.localizationIdentifiers.count == 17)
        let samples: [(AppLanguage, String, String)] = [
            (.english, "Language", "Save / save and quit"),
            (.simplifiedChinese, "语言", "保存／保存并退出"),
            (.traditionalChinese, "語言", "儲存／儲存並結束"),
            (.japanese, "言語", "保存／保存して終了"),
            (.korean, "언어", "저장 / 저장 후 종료"),
            (.french, "Langue", "Enregistrer/enregistrer et quitter"),
            (.german, "Sprache", "Sichern/sichern und beenden"),
            (.spanish, "Idioma", "Guardar/guardar y salir"),
            (.brazilianPortuguese, "Idioma", "Salvar/salvar e sair"),
            (.italian, "Lingua", "Salva/salva ed esci"),
            (.dutch, "Taal", "Bewaren/bewaren en afsluiten"),
            (.russian, "Язык", "Сохранить / сохранить и выйти"),
            (.arabic, "اللغة", "حفظ / حفظ وإنهاء"),
            (.thai, "ภาษา", "บันทึก / บันทึกแล้วออก"),
            (.indonesian, "Bahasa", "Simpan / simpan dan keluar"),
            (.vietnamese, "Ngôn ngữ", "Lưu / lưu rồi thoát"),
            (.turkish, "Dil", "Kaydet / kaydet ve çık"),
            (.english, "Language", "Save / save and quit"),
        ]
        var commandKeys: Set<String>?
        for (language, title, save) in samples {
            AppLocalization.apply(language)
            precondition(AppLocalization.current.identifier == language.rawValue)
            precondition(String(localized: "Language") == title)
            let commands = VimCommandCatalog.ordered(for: .normal)
            precondition(commands.first?.command.explanation == save)
            precondition(VimCommandCatalog.ordered(for: .normal, query: save).first?.command.keys == ":w · :wq")
            let keys = Set(commands.map { $0.command.keys })
            if let commandKeys { precondition(commandKeys == keys) }
            commandKeys = keys
            let userContent = "Language / 语言 / 言語 / العربية"
            let interpolated = String(localized: "Open \(userContent)")
            precondition(interpolated.contains(userContent))
            precondition(String(localized: "A missing translation") == "A missing translation")
            precondition(ProcessInfo.processInfo.processIdentifier == pid)
        }
        let afterApply = UserDefaults.standard.persistentDomain(forName: domain)
        precondition(NSDictionary(dictionary: original ?? [:]) == NSDictionary(dictionary: afterApply ?? [:]))
        let aliases: [(String, AppLanguage)] = [
            ("en-GB", .english), ("zh_CN", .simplifiedChinese), ("zh-SG", .simplifiedChinese),
            ("zh-TW", .traditionalChinese), ("zh-HK", .traditionalChinese),
            ("zh-MO", .traditionalChinese), ("zh-Hans-HK", .simplifiedChinese),
            ("zh-Hant-CN", .traditionalChinese), ("ja-JP", .japanese), ("ko-KR", .korean),
            ("fr-CA", .french), ("de-DE", .german), ("es-MX", .spanish),
            ("pt_BR", .brazilianPortuguese), ("pt-PT", .brazilianPortuguese),
            ("it-IT", .italian), ("nl-NL", .dutch), ("ru-RU", .russian),
            ("ar-SA", .arabic), ("th-TH", .thai), ("id-ID", .indonesian),
            ("vi-VN", .vietnamese), ("tr-TR", .turkish),
        ]
        for (identifier, language) in aliases {
            UserDefaults.standard.set([identifier], forKey: "AppleLanguages")
            precondition(AppLanguage.saved == language, identifier)
            let resolved = AppLocalization.resolve(.system, systemLanguages: [identifier, "en-US"])
            precondition(resolved.identifier == language.rawValue, identifier)
        }
        for language in AppLanguage.allCases where language != .system {
            language.persist()
            precondition(AppLanguage.saved == language)
            precondition(UserDefaults.standard.stringArray(forKey: "AppleLanguages") == [language.rawValue])
        }
        UserDefaults.standard.set(["uk-UA"], forKey: "AppleLanguages")
        precondition(AppLanguage.saved == .system)
        AppLanguage.system.persist()
        precondition(UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        precondition(AppLocalization.resolve(.system, systemLanguages: ["fr-FR", "ja-JP"]).identifier == "fr")
        precondition(AppLocalization.resolve(.system, systemLanguages: ["uk-UA", "ja-JP"]).identifier == "ja")
        precondition(AppLocalization.resolve(.system, systemLanguages: ["uk-UA"]).identifier == "en")
        precondition(AppLocalization.resolve(.english, systemLanguages: ["ja-JP"]).identifier == "en")
        let pluralSamples: [(AppLanguage, Int, String)] = [
            (.english, 1, "%lld match"), (.english, 2, "%lld matches"),
            (.french, 1, "%lld correspondance"), (.french, 2, "%lld correspondances"),
            (.russian, 1, "%lld совпадение"), (.russian, 2, "%lld совпадения"),
            (.russian, 5, "%lld совпадений"), (.russian, 21, "%lld совпадение"),
            (.arabic, 0, "التطابقات: %lld"), (.arabic, 1, "تطابق واحد (%lld)"),
            (.arabic, 2, "تطابقان (%lld)"), (.arabic, 3, "%lld تطابقات"),
            (.arabic, 11, "%lld تطابقًا"), (.arabic, 100, "%lld تطابق"),
        ]
        for (language, count, template) in pluralSamples {
            AppLocalization.apply(language)
            let expected = String(format: template, locale: AppLocalization.current.locale, Int64(count))
            precondition(String(localized: "\(count) matches") == expected, "\(language): \(count)")
        }
        AppLocalization.apply(.system)
        precondition(AppLocalization.current.identifier == AppLocalization.resolve(.system).identifier)
        precondition(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] == globalLanguages)
        print("17 languages, live Vim refresh, interpolation, regional aliases, persistence, plural rules, and system fallback passed")
    }
}
''')
            try:
                subprocess.run([
                    "swiftc", "-parse-as-library", "-module-cache-path", str(root / "modules"),
                    str(mac / "zshell/AppLocalization.swift"),
                    str(mac / "zshell/VimCommandHints.swift"), str(source), "-o", str(executable),
                ], check=True, text=True)
                result = subprocess.run([str(executable)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("passed", result.stdout)
            finally:
                subprocess.run(["defaults", "delete", domain],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
