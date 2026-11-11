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

final class ProbePane: SettingsPaneViewController {
    let support = AgentCLISupportSettingsView(frame: .zero)
    lazy var card = SettingsGroup(rows: [SettingsCustomRow(support)])
    let cellWidth = SettingsSliderRow(
        title: String(localized: "Cell width"), range: 0.75...2, format: .percent,
        step: 0.05, showsStepper: true, symbolName: "arrow.left.and.right",
        symbolColor: SettingsCategory.appearance.iconColor, onChange: { _ in }
    )
    var contrastChanges: [Double] = []
    lazy var contrast = SettingsSliderRow(
        title: String(localized: "Minimum contrast"), range: 1...21, format: .ratio,
        step: 0.1, showsStepper: true, symbolName: "circle.lefthalf.filled",
        symbolColor: SettingsCategory.appearance.iconColor,
        description: String(localized: "Set to 1 to keep original terminal colors."),
        onChange: { [weak self] in self?.contrastChanges.append($0) }
    )
    override func makeGroups() -> [NSView] { [card, SettingsGroup(rows: [cellWidth, contrast])] }
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
                    pane.cellWidth.setValue(hasError ? 2 : 0.75)
                    pane.contrast.setValue(hasError ? 21 : 1)
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
                    let sliderStack = pane.cellWidth.subviews.first as! NSStackView
                    let icon = sliderStack.arrangedSubviews.first as! SettingsIconView
                    let slider = sliderStack.arrangedSubviews.compactMap { $0 as? NSSlider }.first!
                    let contrastStack = pane.contrast.subviews.first as! NSStackView
                    let contrastIcon = contrastStack.arrangedSubviews.first as! SettingsIconView
                    let contrastSlider = contrastStack.arrangedSubviews.compactMap { $0 as? NSSlider }.first!
                    let contrastStepper = contrastStack.arrangedSubviews.compactMap { $0 as? NSStepper }.first!
                    let contrastDescription = pane.contrast.subviews.compactMap { $0 as? NSTextField }.first!
                    let expectedRatio = hasError ? 21.0 : 1.0
                    precondition(contrastSlider.doubleValue == expectedRatio && contrastStepper.doubleValue == expectedRatio)
                    precondition(contrastSlider.accessibilityLabel() == String(localized: "Minimum contrast"))
                    contrastStepper.doubleValue = 7.1
                    contrastStepper.sendAction(contrastStepper.action, to: contrastStepper.target)
                    precondition(pane.contrastChanges.last == 7.1 && contrastSlider.doubleValue == 7.1)
                    contrastSlider.doubleValue = 3.04
                    contrastSlider.sendAction(contrastSlider.action, to: contrastSlider.target)
                    precondition(pane.contrastChanges.last == 3 && contrastStepper.doubleValue == 3)
                    samples.append([
                        "language": language.rawValue, "width": width, "hasError": hasError,
                        "cardHeight": pane.card.frame.height,
                        "rowHeight": pane.support.frame.height,
                        "fittingTextHeight": text.fittingSize.height,
                        "labelCount": labels.count,
                        "cellWidthIconSquare": icon.frame.width == icon.frame.height && icon.frame.width == 32,
                        "cellWidthSliderFits": slider.frame.width > 40 && slider.frame.maxX <= pane.cellWidth.bounds.maxX,
                        "cellWidthLabelsFit": sliderStack.arrangedSubviews.compactMap { $0 as? NSTextField }.allSatisfy {
                            $0.frame.height + 1 >= $0.cell!.cellSize(forBounds: NSRect(
                                x: 0, y: 0, width: $0.frame.width, height: 10000
                            )).height
                        },
                        "contrastIconSquare": contrastIcon.frame.width == 32 && contrastIcon.frame.width == contrastIcon.frame.height,
                        "contrastSliderFits": contrastSlider.frame.width > 40 && contrastStepper.frame.maxX <= pane.contrast.bounds.maxX,
                        "contrastLabelsFit": (contrastStack.arrangedSubviews.compactMap { $0 as? NSTextField } + [contrastDescription]).allSatisfy {
                            $0.frame.height + 1 >= $0.cell!.cellSize(forBounds: NSRect(
                                x: 0, y: 0, width: $0.frame.width, height: 10000
                            )).height
                        },
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
            category = (source / "Settings/SettingsWindowController.swift").read_text()
            category = category[category.index("enum SettingsCategory:"):category.index("    func makePane()")]
            harness.write_text(HARNESS.replace("import Combine\n", "import Combine\n" + category + "}\n", 1))
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
                    self.assertTrue(sample["cellWidthIconSquare"], sample)
                    self.assertTrue(sample["cellWidthSliderFits"], sample)
                    self.assertTrue(sample["cellWidthLabelsFit"], sample)
                    self.assertTrue(sample["contrastIconSquare"], sample)
                    self.assertTrue(sample["contrastSliderFits"], sample)
                    self.assertTrue(sample["contrastLabelsFit"], sample)
                    self.assertAlmostEqual(sample["rowHeight"], sample["fittingTextHeight"], delta=1)
                    self.assertLess(sample["cardHeight"], 180, sample)
                    self.assertGreater(sample["rowHeight"], 20, sample)


if __name__ == "__main__":
    unittest.main()
