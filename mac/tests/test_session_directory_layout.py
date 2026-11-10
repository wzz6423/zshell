"""Exercise the AppKit session directory editor in every supported language and narrow widths."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''import AppKit

// Only category metadata is a fixture; the editor, settings rows, and language
// resolution are production code and no terminal or app services are started.
enum SettingsCategory: CaseIterable {
    case general, appearance, terminal, browser
    var symbolName: String { "" }
    var iconColor: NSColor { .gray }
}

@main @MainActor struct DirectoryLayoutProbe {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var samples: [[String: Any]] = []
        for language in AppLanguage.allCases where language != .system {
            AppLocalization.apply(language)
            let editor = TerminalSessionDirectorySettingsView { _, _ in }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView()
            window.contentView = content
            editor.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(editor)
            NSLayoutConstraint.activate([
                editor.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                editor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
                editor.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            ])
            for width in [480.0, 660, 900, 480] {
                window.setContentSize(NSSize(width: width, height: 600))
                for policy in NewSessionDirectoryPolicy.allCases {
                    for path in ["relative", NSHomeDirectory()] {
                        editor.apply(policy: policy, directory: path)
                        for _ in 0..<3 {
                            content.layoutSubtreeIfNeeded()
                            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                        }
                        let labels = descendants(editor).compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.isHidden }
                        let field = descendants(editor).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
                        let popup = descendants(editor).compactMap { $0 as? NSPopUpButton }.first!
                        samples.append([
                            "language": language.rawValue, "width": width, "policy": policy.rawValue,
                            "valid": path != "relative", "height": editor.frame.height,
                            "selection": popup.indexOfSelectedItem,
                            "labelCount": labels.count,
                            "labelsFit": labels.allSatisfy {
                                $0.frame.height + 1 >= $0.cell!.cellSize(forBounds: NSRect(
                                    x: 0, y: 0, width: $0.frame.width, height: 10000)).height
                            },
                            "fieldVisible": field.ancestorHidden == false,
                            "controlsFit": editor.bounds.contains(editor.convert(popup.bounds, from: popup))
                                && (policy != .custom || editor.bounds.contains(editor.convert(field.bounds, from: field))),
                            "choices": popup.itemTitles,
                        ])
                    }
                }
            }
            window.close()
        }
        print(String(data: try JSONSerialization.data(withJSONObject: samples), encoding: .utf8)!)
    }
}

extension NSView {
    var ancestorHidden: Bool { isHidden || superview?.ancestorHidden == true }
}
'''

with tempfile.TemporaryDirectory(prefix="zshell-directory-layout-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "DirectoryLayout.app/Contents"
    binary = contents / "MacOS/probe"
    resources = contents / "Resources"
    binary.parent.mkdir(parents=True)
    resources.mkdir()
    identifier = "sh.zshell.directory-layout." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": binary.name,
        "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL",
    }))
    sources = ROOT / "mac/zshell"
    subprocess.run(["xcrun", "xcstringstool", "compile", str(sources / "Localizable.xcstrings"),
                    "--output-directory", str(resources)], check=True, capture_output=True, text=True)
    script = temporary / "Probe.swift"
    script.write_text(HARNESS)
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(temporary / "modules"),
        str(sources / "AppLocalization.swift"), str(sources / "TerminalSessionDirectory.swift"),
        str(sources / "Settings/SettingsRows.swift"), str(sources / "Settings/SettingsPaneKit.swift"),
        str(sources / "Settings/TerminalSessionDirectorySettingsView.swift"), str(script), "-o", str(binary),
    ], cwd=ROOT, check=True)
    try:
        samples = json.loads(subprocess.check_output([str(binary)], text=True, timeout=60))
        assert len(samples) == 17 * 4 * 4 * 2, len(samples)
        for sample in samples:
            assert sample["labelCount"] == 2 and sample["labelsFit"] and sample["controlsFit"], sample
            assert sample["fieldVisible"] == (sample["policy"] == "custom"), sample
            assert sample["selection"] == ["current", "project", "home", "custom"].index(sample["policy"]), sample
            assert len(sample["choices"]) == 4, sample
        print(f'DirectorySettingsLayout: {len(samples)} language, width, policy, and validation samples passed')
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", identifier], capture_output=True, timeout=10)
        (Path.home() / "Library/Preferences" / f"{identifier}.plist").unlink(missing_ok=True)
