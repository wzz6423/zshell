"""Exercise real AppKit settings cards across language and width changes."""

import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import uuid


REPO = Path(__file__).resolve().parents[2]

HARNESS = r'''
import AppKit
import Combine

// The pane only needs its settings publisher; no app services run in this probe.
final class AppSettings: ObservableObject { static let shared = AppSettings() }
enum SettingsCategory {
    case automation
    var title: String { String(localized: "AI") }
}

final class ProbePane: SettingsPaneViewController {
    let support = AgentCLISupportSettingsView(frame: .zero)
    lazy var card = SettingsGroup(rows: [SettingsCustomRow(support)])
    override func makeGroups() -> [NSView] { [card] }
}

@main struct LayoutProbe {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var samples: [[String: Any]] = []
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let pane = ProbePane()
            pane.setCategory(.automation)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            let toggle = pane.support.subviews.compactMap { $0 as? NSSwitch }.first!
            let text = pane.support.subviews.compactMap { $0 as? NSStackView }.first!
            for width in [660.0, 480, 900, 480, 660] {
                window.setContentSize(NSSize(width: width, height: 460))
                for hasError in [false, true, false] {
                    pane.support.changeHandler = { _ in
                        if hasError {
                            throw NSError(domain: "LayoutProbe", code: 1, userInfo: [
                                NSLocalizedDescriptionKey:
                                    "The integration could not be enabled. Check the configuration directory permissions and try again."
                            ])
                        }
                    }
                    toggle.performClick(nil)
                    for _ in 0..<3 {
                        pane.view.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
                    }
                    let labels = text.arrangedSubviews.compactMap { $0 as? NSTextField }
                        .filter { !$0.isHidden }
                    samples.append([
                        "language": language.rawValue, "width": width, "hasError": hasError,
                        "cardHeight": pane.card.frame.height,
                        "rowHeight": pane.support.frame.height,
                        "fittingTextHeight": text.fittingSize.height,
                        "labelCount": labels.count,
                        "labelsFit": labels.allSatisfy {
                            $0.frame.height + 1 >= $0.cell!.cellSize(forBounds: NSRect(
                                x: 0, y: 0, width: $0.frame.width, height: 10000
                            )).height
                        },
                    ])
                }
            }
            window.close()
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: samples))
    }
}
'''


class SettingsLayoutTests(unittest.TestCase):
    def test_card_fits_wrapped_text_after_resize_and_error_changes(self):
        with tempfile.TemporaryDirectory(prefix="zshell-settings-layout-") as temporary:
            root = Path(temporary)
            contents = root / "LayoutProbe.app/Contents"
            resources = contents / "Resources"
            resources.mkdir(parents=True)
            binary = contents / "MacOS/LayoutProbe"
            binary.parent.mkdir()
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "sh.zshell.settings-layout-test." + uuid.uuid4().hex,
                "CFBundleExecutable": binary.name,
                "CFBundleDevelopmentRegion": "en",
                "CFBundlePackageType": "APPL",
            }))
            source = REPO / "mac/zshell"
            subprocess.run([
                "xcrun", "xcstringstool", "compile", str(source / "Localizable.xcstrings"),
                "--output-directory", str(resources),
            ], check=True, capture_output=True, text=True)
            harness = root / "Harness.swift"
            harness.write_text(HARNESS)
            subprocess.run([
                "swiftc", "-parse-as-library", "-module-cache-path", str(root / "modules"),
                str(source / "AppLocalization.swift"),
                str(source / "AgentCLISupportSettingsView.swift"),
                str(source / "Settings/SettingsRows.swift"),
                str(source / "Settings/SettingsPaneKit.swift"),
                str(source / "Settings/SettingsPaneViewController.swift"),
                str(harness), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            samples = json.loads(subprocess.check_output([str(binary)], text=True, timeout=30))
            self.assertEqual(len({sample["language"] for sample in samples}), 17)
            self.assertEqual(len(samples), 17 * 5 * 3)
            for sample in samples:
                with self.subTest(language=sample["language"], width=sample["width"],
                                  has_error=sample["hasError"]):
                    self.assertEqual(sample["labelCount"], 3 if sample["hasError"] else 2)
                    self.assertTrue(sample["labelsFit"], sample)
                    self.assertAlmostEqual(sample["rowHeight"], sample["fittingTextHeight"], delta=1)
                    self.assertLess(sample["cardHeight"], 180, sample)
                    self.assertGreater(sample["rowHeight"], 20, sample)


if __name__ == "__main__":
    unittest.main()
