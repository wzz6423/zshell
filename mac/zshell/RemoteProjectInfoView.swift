//
//  RemoteProjectInfoView.swift
//  zshell
//

import AppKit
import Combine
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
final class RemoteProjectInfoNSView: NSView {
    private let statusValue = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let hostValue = NSTextField(labelWithString: "")
    private let userValue = NSTextField(labelWithString: "")
    private let portValue = NSTextField(labelWithString: "")
    private let directoryValue = NSTextField(labelWithString: "")
    private weak var project: Project?
    private var connectionObservation: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        statusValue.font = .systemFont(ofSize: 12, weight: .medium)
        statusDetail.font = .systemFont(ofSize: 11)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.maximumNumberOfLines = 0
        statusDetail.isHidden = true

        let fields = NSStackView(views: [
            row(String(localized: "Status"), statusValue),
            row(String(localized: "Host"), hostValue),
            row(String(localized: "User"), userValue),
            row(String(localized: "Port"), portValue),
            row(String(localized: "Remote Directory"), directoryValue),
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        for row in fields.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [fields, statusDetail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(project: Project) {
        guard case .ssh(let endpoint, let remoteDirectory, _, _) = project.location else {
            return
        }
        if self.project !== project {
            self.project = project
            connectionObservation = project.$remoteConnectionState
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshConnectionState($0) }
        }
        hostValue.stringValue = endpoint.host
        userValue.stringValue = endpoint.user ?? "—"
        portValue.stringValue = endpoint.port.map(String.init) ?? "—"
        directoryValue.stringValue = remoteDirectory ?? "~"
        for value in [hostValue, userValue, portValue, directoryValue] {
            value.toolTip = value.stringValue
        }

        refreshConnectionState(project.remoteConnectionState)
    }

    private func refreshConnectionState(_ state: RemoteConnectionState) {
        switch state {
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

    private func row(_ title: String, _ value: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        value.lineBreakMode = .byTruncatingMiddle
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, value])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        for field in [label, value] {
            field.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        return row
    }
}
