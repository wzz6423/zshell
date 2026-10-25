//
//  AppKitGitFilterView.swift
//  zshell
//

import AppKit
import SwiftUI

struct GitChangedFilesSearchField: NSViewRepresentable {
    @Binding var text: String
    let fontScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .small
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: 11 * fontScale)
        field.placeholderString = String(localized: "Filter changed files")
        field.setAccessibilityLabel(field.placeholderString)
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: GitChangedFilesSearchField

        init(parent: GitChangedFilesSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
