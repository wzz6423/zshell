//
//  RowButtonTableView.swift
//  zshell
//

import AppKit

/// NSTableView that lets mouse-downs through to buttons inside its rows.
///
/// By default NSTableView claims every `leftMouseDown` inside itself — its
/// `validateProposedFirstResponder` override refuses to pass the event to
/// subviews — so an NSButton embedded in a row never receives the mouse-down
/// and can never respond to a click. The table selects the row and fires its
/// action instead, which is why the row's edit/delete buttons used to behave
/// exactly like a click on the row body.
///
/// Allowing a row's buttons to become the event's first responder lets them
/// track the click and fire their own action; clicks on the row body keep
/// selecting the row and firing the table's action as before.
final class RowButtonTableView: NSTableView {
    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        if event?.type == .leftMouseDown,
           let view = responder as? NSView,
           view !== self, view.isDescendant(of: self),
           view is NSButton {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}
