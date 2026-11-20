"""Exercise real AppKit settings cards across language and width changes."""

import json
from pathlib import Path
import plistlib
import re
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

// Only tool scanning/installing is replaced; the recommendation pane and row creation are production code.
struct RecommendedToolState {
    enum Location { case homebrew, external }
    var hasCheckedInstallation = false
    var installedVersion: String?
    var location: Location?
    var latestVersion: String?
    var error: String?
    var isInstalled: Bool { location != nil }
    var hasUpdate: Bool { installedVersion != nil && latestVersion != nil && installedVersion != latestVersion }
}
final class RecommendedToolService: ObservableObject {
    static weak var fixture: RecommendedToolService?
    @Published var states: [RecommendedTool: RecommendedToolState] = [:]
    var isRefreshing = false
    var isBusy = false
    var activeTool: RecommendedTool?
    var homebrewURL: URL?
    var error: String?
    var missingTools: [RecommendedTool] { [] }
    var updatableTools: [RecommendedTool] { [] }
    init() { Self.fixture = self }
    func refresh(force: Bool = false) async {}
    func install(_ tools: [RecommendedTool]) async {}
}
struct SettingsVisibility {
    struct Recommendations {
        var homebrewAvailable: Bool
        var hasMissingTools: Bool
        var hasUpdatableTools: Bool
        var installMissing: Bool { homebrewAvailable && hasMissingTools }
        var updateAll: Bool { homebrewAvailable && hasUpdatableTools }
    }
    static func updateRecommendations(_ recommendations: Recommendations) {}
}

final class ProbePane: SettingsPaneViewController {
    let support = AgentCLISupportSettingsView(frame: .zero)
    lazy var card = SettingsGroup(rows: [SettingsCustomRow(support)])
    let cellWidth = SettingsSliderRow(
        title: String(localized: "Cell width"), range: 0.75...2, format: .percent,
        step: 0.05, showsStepper: true, symbolName: "arrow.left.and.right",
        symbolColor: SettingsCategory.appearance.iconColor, onChange: { _ in }
    )
    let cursorShape = TerminalCursorShapeSettingsView(frame: .zero)
    let cursorBlinking = TerminalCursorBlinkingSettingsView(frame: .zero)
    let wrappedTitle = SettingsRow(
        title: String(localized: "Double-click empty space to create a session"),
        description: String(localized: "Copy Finder files and folders into local projects. File → Import Files… is always available."),
        control: SettingsSwitch { _ in }
    )
    let editorRow = SettingsRow(title: String(localized: "External editor"), control: SettingsSwitch { _ in })
    let backend = SettingsBackendPicker { _ in }
    let ordinarySlider = SettingsSliderRow(
        title: String(localized: "Line height"), range: 0.75...2, format: .percent,
        step: 0.05, showsStepper: true, onChange: { _ in }
    )
    var contrastChanges: [Double] = []
    lazy var contrast = SettingsSliderRow(
        title: String(localized: "Minimum contrast"), range: 1...21, format: .ratio,
        step: 0.1, showsStepper: true, symbolName: "circle.lefthalf.filled",
        symbolColor: SettingsCategory.appearance.iconColor,
        description: String(localized: "Set to 1 to keep original terminal colors."),
        onChange: { [weak self] in self?.contrastChanges.append($0) }
    )
    override func makeGroups() -> [NSView] {
        [card, SettingsGroup(rows: [cellWidth, contrast, ordinarySlider]),
         SettingsGroup(rows: [wrappedTitle, editorRow, SettingsCustomRow(cursorShape), SettingsCustomRow(cursorBlinking), SettingsCustomRow(backend)])]
    }
}

@main struct LayoutProbe {
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor static func iconMatchesTitle(in row: NSView, size: CGFloat = 32) -> Bool {
        guard let icon = descendants(row).compactMap({ $0 as? SettingsIconView }).first,
              let title = descendants(row).compactMap({ $0 as? NSTextField }).first(where: {
                  $0.font?.pointSize == NSFont.systemFontSize
              }), let font = title.font else { return false }
        let bounds = row.convert(icon.bounds, from: icon)
        let titleBounds = row.convert(title.bounds, from: title)
        let titleCenter = titleBounds.maxY - title.firstBaselineOffsetFromTop + (font.ascender + font.descender) / 2
        return abs(bounds.width - size) < 0.5
            && abs(bounds.width - bounds.height) < 0.5
            && abs(bounds.midY - titleCenter) <= 1
            && bounds.maxX < titleBounds.minX && bounds.minX >= 0
    }

    @MainActor static func iconRendersGlyph(in row: NSView) -> Bool {
        guard let icon = descendants(row).compactMap({ $0 as? SettingsIconView }).first else { return false }
        let bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds)!
        icon.cacheDisplay(in: icon.bounds, to: bitmap)
        return (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.85
            }
        }
    }

    @MainActor static func glyphGeometry(named name: String, size: CGFloat, appearance: NSAppearance.Name) -> [String: Any] {
        let icon = SettingsIconView(symbolName: name, color: .systemIndigo, size: size)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let content = NSView()
        window.contentView = content
        content.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
        ])
        content.layoutSubtreeIfNeeded()
        let bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds)!
        icon.cacheDisplay(in: icon.bounds, to: bitmap)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.85 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        precondition(maxX >= minX && maxY >= minY)
        let scaleX = icon.bounds.width / CGFloat(bitmap.pixelsWide)
        let scaleY = icon.bounds.height / CGFloat(bitmap.pixelsHigh)
        let reference = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!
        let referenceBitmap = NSBitmapImageRep(cgImage: reference.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        var referenceMinX = referenceBitmap.pixelsWide, referenceMinY = referenceBitmap.pixelsHigh
        var referenceMaxX = -1, referenceMaxY = -1
        for y in 0..<referenceBitmap.pixelsHigh {
            for x in 0..<referenceBitmap.pixelsWide where (referenceBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.85 {
                referenceMinX = min(referenceMinX, x); referenceMaxX = max(referenceMaxX, x)
                referenceMinY = min(referenceMinY, y); referenceMaxY = max(referenceMaxY, y)
            }
        }
        var cutoutSamples = 0, cutoutMismatches = 0
        if name == "star.circle.fill" || name == "arrow.down.circle.fill" {
            for y in 0..<15 {
                for x in 0..<15 {
                    let fractionX = 0.1 + (Double(x) + 0.5) / 15 * 0.8
                    let fractionY = 0.1 + (Double(y) + 0.5) / 15 * 0.8
                    let referenceX = referenceMinX + Int(fractionX * Double(referenceMaxX - referenceMinX + 1))
                    let referenceY = referenceMinY + Int(fractionY * Double(referenceMaxY - referenceMinY + 1))
                    let alpha = referenceBitmap.colorAt(x: referenceX, y: referenceY)!.alphaComponent
                    guard alpha < 0.15 || alpha > 0.85 else { continue }
                    let actualX = minX + Int(fractionX * Double(maxX - minX + 1))
                    let actualY = minY + Int(fractionY * Double(maxY - minY + 1))
                    let color = bitmap.colorAt(x: actualX, y: actualY)!.usingColorSpace(.deviceRGB)!
                    let isWhite = min(color.redComponent, color.greenComponent, color.blueComponent) > 0.85
                    cutoutSamples += 1
                    if isWhite != (alpha > 0.85) { cutoutMismatches += 1 }
                }
            }
        }
        window.close()
        return [
            "symbol": name,
            "tileSize": size,
            "appearance": appearance.rawValue,
            "pixelSize": max(scaleX, scaleY),
            "cutoutSamples": cutoutSamples,
            "cutoutMismatchFraction": Double(cutoutMismatches) / Double(max(cutoutSamples, 1)),
            "centerXOffset": CGFloat(minX + maxX + 1) / 2 * scaleX - icon.bounds.midX,
            "centerYOffset": CGFloat(minY + maxY + 1) / 2 * scaleY - icon.bounds.midY,
            "visibleWidth": CGFloat(maxX - minX + 1) * scaleX,
            "visibleHeight": CGFloat(maxY - minY + 1) * scaleY,
            "referenceWidth": CGFloat(referenceMaxX - referenceMinX + 1) * reference.size.width / CGFloat(referenceBitmap.pixelsWide),
            "referenceHeight": CGFloat(referenceMaxY - referenceMinY + 1) * reference.size.height / CGFloat(referenceBitmap.pixelsHigh),
        ]
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var samples: [[String: Any]] = []
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let pane = ProbePane()
            let sidebar = SettingsSidebarRow(category: .editor)
            sidebar.translatesAutoresizingMaskIntoConstraints = false
            let sidebarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                         styleMask: [.titled], backing: .buffered, defer: false)
            sidebarWindow.isReleasedWhenClosed = false
            let sidebarContent = NSView()
            sidebarWindow.contentView = sidebarContent
            sidebarContent.addSubview(sidebar)
            NSLayoutConstraint.activate([
                sidebar.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor),
                sidebar.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor),
                sidebar.topAnchor.constraint(equalTo: sidebarContent.topAnchor),
            ])
            let recommendations = SettingsRecommendationsPane()
            let recommendationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                                                styleMask: [.titled], backing: .buffered, defer: false)
            recommendationWindow.isReleasedWhenClosed = false
            recommendationWindow.contentViewController = recommendations
            let downloadButton = descendants(recommendations.view).compactMap { $0 as? SettingsActionButton }.first {
                $0.accessibilityLabel() == String(localized: "Manage \(RecommendedTool.quietMD.name)")
            }!
            let toolActions = downloadButton.superview as! NSStackView
            var ancestor: NSView? = toolActions
            while !(ancestor is SettingsRow) { ancestor = ancestor?.superview }
            let toolRow = ancestor as! SettingsRow
            let toolService = RecommendedToolService.fixture!
            pane.setCategory(.automation)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            let toggle = pane.support.subviews.compactMap { $0 as? NSSwitch }.first!
            let text = pane.support.subviews.compactMap { $0 as? NSStackView }.first!
            for width in [760.0, 470, 900, 470, 760] {
                window.setContentSize(NSSize(width: width, height: 460))
                recommendationWindow.setContentSize(NSSize(width: width, height: 640))
                for hasError in [false, true, false] {
                    pane.cellWidth.setValue(hasError ? 2 : 0.75)
                    pane.contrast.setValue(hasError ? 21 : 1)
                    toolService.states[.quietMD] = RecommendedToolState(
                        hasCheckedInstallation: true, installedVersion: "1", location: .external,
                        latestVersion: hasError ? "2" : "1"
                    )
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
                        recommendations.view.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
                    }
                    sidebar.isSelectedRow = hasError
                    sidebarContent.layoutSubtreeIfNeeded()
                    let backendHeaders = descendants(pane.backend).compactMap { $0 as? NSStackView }.filter {
                        $0.orientation == .horizontal && $0.arrangedSubviews.first is NSImageView
                            && $0.arrangedSubviews.last is NSTextField
                    }
                    let labels = text.arrangedSubviews.compactMap { $0 as? NSTextField }
                        .filter { !$0.isHidden }
                    let sliderStack = pane.cellWidth.subviews.first as! NSStackView
                    let slider = sliderStack.arrangedSubviews.compactMap { $0 as? NSSlider }.first!
                    let contrastStack = pane.contrast.subviews.first as! NSStackView
                    let contrastSlider = contrastStack.arrangedSubviews.compactMap { $0 as? NSSlider }.first!
                    let contrastStepper = contrastStack.arrangedSubviews.compactMap { $0 as? NSStepper }.first!
                    let contrastDescription = pane.contrast.subviews.compactMap { $0 as? NSTextField }.first!
                    let expectedRatio = hasError ? 21.0 : 1.0
                    precondition(downloadButton.title == (hasError ? String(localized: "Download Update") : String(localized: "Download")))
                    let actionsRect = toolRow.convert(toolActions.bounds, from: toolActions)
                    let downloadRect = toolRow.convert(
                        downloadButton.alignmentRect(forFrame: downloadButton.frame), from: toolActions
                    )
                    precondition(contrastSlider.doubleValue == expectedRatio && contrastStepper.doubleValue == expectedRatio)
                    precondition(contrastSlider.accessibilityLabel() == String(localized: "Minimum contrast"))
                    samples.append([
                        "language": language.rawValue, "width": width, "hasError": hasError,
                        "cardHeight": pane.card.frame.height,
                        "rowHeight": pane.support.frame.height,
                        "fittingTextHeight": text.fittingSize.height,
                        "labelCount": labels.count,
                        "toolActionsTrailingGap": toolRow.bounds.maxX - actionsRect.maxX,
                        "downloadTrailingGap": toolRow.bounds.maxX - downloadRect.maxX,
                        "toolButtonsFit": toolActions.arrangedSubviews.allSatisfy {
                            abs($0.frame.width - $0.fittingSize.width) <= 2 && $0.frame.minX >= 0
                                && $0.frame.maxX <= toolActions.bounds.maxX + 2
                        },
                        "cellWidthIconSquare": iconMatchesTitle(in: pane.cellWidth),
                        "cellWidthSliderFits": slider.frame.width > 40 && slider.frame.maxX <= pane.cellWidth.bounds.maxX,
                        "cellWidthLabelsFit": descendants(sliderStack).compactMap { $0 as? NSTextField }.allSatisfy {
                            $0.frame.height + 1 >= $0.cell!.cellSize(forBounds: NSRect(
                                x: 0, y: 0, width: $0.frame.width, height: 10000
                            )).height
                        },
                        "contrastIconSquare": iconMatchesTitle(in: pane.contrast),
                        "sharedAndCustomIconsMatchTitles": [pane.support, pane.wrappedTitle, pane.editorRow,
                            pane.ordinarySlider, pane.cursorShape, pane.cursorBlinking].allSatisfy { iconMatchesTitle(in: $0) },
                        "externalEditorIconVisible": iconRendersGlyph(in: pane.editorRow),
                        "sidebarIconMatchesTitle": iconMatchesTitle(in: sidebar, size: 24),
                        "backendIconsMatchTitles": backendHeaders.filter { $0.arrangedSubviews.count == 2
                            && ($0.arrangedSubviews.last as? NSTextField)?.font?.pointSize == NSFont.systemFontSize
                        }.count == TerminalBackend.selectable.count && backendHeaders.filter {
                            ($0.arrangedSubviews.last as? NSTextField)?.font?.pointSize == NSFont.systemFontSize
                        }.allSatisfy { header in
                            let icon = header.arrangedSubviews.first!, name = header.arrangedSubviews.last as! NSTextField
                            return abs(icon.frame.height - 32) < 0.5
                                && abs(icon.frame.width - icon.frame.height) < 0.5
                                && icon.frame.maxX <= name.frame.minX
                        },
                        "wrappedTitleFits": descendants(pane.wrappedTitle).compactMap { $0 as? NSTextField }.allSatisfy {
                            $0.frame.height + 1 >= $0.cell!.cellSize(forBounds: NSRect(
                                x: 0, y: 0, width: $0.frame.width, height: 10000
                            )).height
                        },
                        "contrastSliderFits": contrastSlider.frame.width > 40 && contrastStepper.frame.maxX <= pane.contrast.bounds.maxX,
                        "contrastLabelsFit": (descendants(contrastStack).compactMap { $0 as? NSTextField } + [contrastDescription]).allSatisfy {
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
                    contrastStepper.doubleValue = 7.1
                    contrastStepper.sendAction(contrastStepper.action, to: contrastStepper.target)
                    precondition(pane.contrastChanges.last == 7.1 && contrastSlider.doubleValue == 7.1)
                    contrastSlider.doubleValue = 3.04
                    contrastSlider.sendAction(contrastSlider.action, to: contrastSlider.target)
                    precondition(pane.contrastChanges.last == 3 && contrastStepper.doubleValue == 3)
                }
            }
            window.close()
            sidebarWindow.close()
            recommendationWindow.close()
        }
        let glyphs = [NSAppearance.Name.aqua, .darkAqua].flatMap { appearance in
            [24.0, 32.0].flatMap { size in
                Array(Set(SettingsCategory.allCases.map(\.symbolName) + mappedRowSymbols)).sorted()
                    .map { glyphGeometry(named: $0, size: size, appearance: appearance) }
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["samples": samples, "glyphs": glyphs]))
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
            cursor = (source / "TerminalCursorSettings.swift").read_text()
            cursor = cursor[cursor.index("enum TerminalCursorShape:"):cursor.index("    var ghosttyValue:")] + "}\n"
            backend = (source / "TerminalBackend.swift").read_text()
            backend = backend[backend.index("enum TerminalBackend:"):backend.index("    /// Builds this backend's surface")] + "}\n"
            backend += "struct TerminalBackendHighlight { let title: String; let isPositive: Bool }\n"
            sidebar = (source / "Settings/SettingsSidebar.swift").read_text()
            sidebar = sidebar[sidebar.index("private final class SettingsSidebarRow:"):].replace(
                "private final class SettingsSidebarRow:", "final class SettingsSidebarRow:", 1)
            search_result = "struct SettingsSearchResult { let category: SettingsCategory; let title: String; let section: String? }\n"
            pane_kit = (source / "Settings/SettingsPaneKit.swift").read_text()
            symbols = re.findall(r'Icon\(name:\s*"([^"]+)"', pane_kit)
            symbols.extend(re.findall(r'\],\s*"([^"]+)"\s*,\s*\.', pane_kit))
            symbols.extend(re.findall(r'^\s*"([^"]+)",\s*\.[a-z]+\),', pane_kit, re.M))
            for path in list((source / "Settings").glob("*.swift")) + [
                source / "TerminalCursorSettingsView.swift", source / "AgentCLISupportSettingsView.swift",
            ]:
                symbols.extend(re.findall(r'symbolName:\s*"([^"]+)"', path.read_text()))
            mapped_symbols = "let mappedRowSymbols = " + json.dumps(list(dict.fromkeys(symbols))) + "\n"
            harness.write_text(HARNESS.replace("import Combine\n", "import Combine\n" + category + "}\n" + cursor + backend + search_result + sidebar + mapped_symbols, 1))
            subprocess.run([
                "swiftc", "-parse-as-library", "-module-cache-path", str(root / "modules"),
                str(source / "AppLocalization.swift"),
                str(source / "AgentCLISupportSettingsView.swift"),
                str(source / "TerminalCursorSettingsView.swift"),
                str(source / "Settings/SettingsRows.swift"),
                str(source / "RecommendedTool.swift"),
                str(source / "Settings/SettingsRecommendationsPane.swift"),
                str(source / "Settings/SettingsBackendPicker.swift"),
                str(source / "Settings/SettingsCardButton.swift"),
                str(source / "Settings/SettingsPaneKit.swift"),
                str(source / "Settings/SettingsPaneViewController.swift"),
                str(harness), "-o", str(binary),
            ], check=True, capture_output=True, text=True)
            result = json.loads(subprocess.check_output([str(binary)], text=True, timeout=30))
            samples = result["samples"]
            for glyph in result["glyphs"]:
                with self.subTest(symbol=glyph["symbol"], tile_size=glyph["tileSize"], appearance=glyph["appearance"]):
                    if glyph["symbol"] in ("star.circle.fill", "arrow.down.circle.fill"):
                        self.assertGreater(glyph["cutoutSamples"], 100, glyph)
                        self.assertLessEqual(glyph["cutoutMismatchFraction"], 0.05, glyph)
                    self.assertAlmostEqual(glyph["centerXOffset"], 0, delta=glyph["pixelSize"] / 2, msg=glyph)
                    self.assertAlmostEqual(glyph["centerYOffset"], 0, delta=glyph["pixelSize"] / 2, msg=glyph)
                    self.assertAlmostEqual(glyph["visibleWidth"], glyph["referenceWidth"], delta=1, msg=glyph)
                    self.assertAlmostEqual(glyph["visibleHeight"], glyph["referenceHeight"], delta=1, msg=glyph)
            self.assertEqual(len({sample["language"] for sample in samples}), 17)
            self.assertEqual(len(samples), 17 * 5 * 3)
            for sample in samples:
                with self.subTest(language=sample["language"], width=sample["width"],
                                  has_error=sample["hasError"]):
                    self.assertEqual(sample["labelCount"], 3 if sample["hasError"] else 2)
                    self.assertAlmostEqual(sample["toolActionsTrailingGap"], 0, delta=2, msg=sample)
                    self.assertAlmostEqual(sample["downloadTrailingGap"], 0, delta=2, msg=sample)
                    self.assertTrue(sample["toolButtonsFit"], sample)
                    self.assertTrue(sample["labelsFit"], sample)
                    self.assertTrue(sample["cellWidthIconSquare"], sample)
                    self.assertTrue(sample["cellWidthSliderFits"], sample)
                    self.assertTrue(sample["cellWidthLabelsFit"], sample)
                    self.assertTrue(sample["contrastIconSquare"], sample)
                    self.assertTrue(sample["sharedAndCustomIconsMatchTitles"], sample)
                    self.assertTrue(sample["externalEditorIconVisible"], sample)
                    self.assertTrue(sample["wrappedTitleFits"], sample)
                    self.assertTrue(sample["sidebarIconMatchesTitle"], sample)
                    self.assertTrue(sample["backendIconsMatchTitles"], sample)
                    self.assertTrue(sample["contrastSliderFits"], sample)
                    self.assertTrue(sample["contrastLabelsFit"], sample)
                    self.assertAlmostEqual(sample["rowHeight"], sample["fittingTextHeight"], delta=1)
                    self.assertLess(sample["cardHeight"], 180, sample)
                    self.assertGreater(sample["rowHeight"], 20, sample)


if __name__ == "__main__":
    unittest.main()
