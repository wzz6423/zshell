//
//  AppKitGitFilterView.swift
//  zshell
//

import AppKit
import SwiftUI

final class GitPanelSearchField: NSSearchField, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        controlSize = .small
        sendsSearchStringImmediately = true
        sendsWholeSearchString = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String, placeholder: String, fontScale: CGFloat) {
        font = .systemFont(ofSize: 11 * fontScale)
        placeholderString = placeholder
        setAccessibilityLabel(placeholder)
        if stringValue != text {
            stringValue = text
            currentEditor()?.string = text
        }
    }

    func controlTextDidChange(_ notification: Notification) { onChange?(stringValue) }
}

struct GitChangedFilesSearchField: NSViewRepresentable {
    @Binding var text: String
    let fontScale: CGFloat

    func makeNSView(context: Context) -> GitPanelSearchField {
        GitPanelSearchField()
    }

    func updateNSView(_ field: GitPanelSearchField, context: Context) {
        field.onChange = { text = $0 }
        field.update(text: text, placeholder: String(localized: "Filter changed files"), fontScale: fontScale)
    }
}
