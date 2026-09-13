//
//  RemoteProjectInfoView.swift
//  zshell
//

import AppKit
import SwiftUI

/// Info panel content for SSH projects: the declared remote and the outcome
/// of the connectivity probe taken when the project was created. The panel
/// states what was declared; it never opens the remote path on this Mac.
struct RemoteProjectInfoView: NSViewRepresentable {
    @ObservedObject var project: Project

    func makeNSView(context: Context) -> RemoteProjectInfoNSView {
        RemoteProjectInfoNSView()
    }

    func updateNSView(_ nsView: RemoteProjectInfoNSView, context: Context) {
        nsView.configure(project: project)
    }
}

@MainActor
private final class RemoteProjectInfoNSView: NSView {
    private let statusValue = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let hostValue = NSTextField(labelWithString: "")
    private let userValue = NSTextField(labelWithString: "")
    private let portValue = NSTextField(labelWithString: "")
    private let directoryValue = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        statusValue.font = .systemFont(ofSize: 12, weight: .medium)
        statusDetail.font = .systemFont(ofSize: 11)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.maximumNumberOfLines = 0
        statusDetail.isHidden = true

        let grid = NSGridView(views: [
            row(String(localized: "Status"), statusValue),
            row(String(localized: "Host"), hostValue),
            row(String(localized: "User"), userValue),
            row(String(localized: "Port"), portValue),
            row(String(localized: "Remote Directory"), directoryValue),
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 200
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [grid, statusDetail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 16
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -16
            ),
            statusDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(project: Project) {
        guard case .ssh(let endpoint, let remoteDirectory) = project.location else {
            return
        }
        hostValue.stringValue = endpoint.host
        userValue.stringValue = endpoint.user ?? "—"
        portValue.stringValue = endpoint.port.map(String.init) ?? "—"
        directoryValue.stringValue = remoteDirectory ?? "~"

        switch project.remoteConnectionState {
        case .checking:
            statusValue.stringValue = String(localized: "Connecting…")
            statusValue.textColor = .secondaryLabelColor
            statusDetail.isHidden = true
        case .connected:
            statusValue.stringValue = String(localized: "Connected")
            statusValue.textColor = .systemGreen
            statusDetail.isHidden = true
        case .failed(let message):
            statusValue.stringValue = String(localized: "Connection failed")
            statusValue.textColor = .systemRed
            statusDetail.stringValue = message
            statusDetail.isHidden = message.isEmpty
        }
    }

    private func row(_ title: String, _ value: NSTextField) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return [label, value]
    }
}
