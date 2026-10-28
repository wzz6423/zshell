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
    private let reconnectButton = NSButton()
    private let controlButton = NSButton()
    private let detachButton = NSButton()
    private let remoteControls = NSStackView()
    private weak var project: Project?
    private weak var observedSession: TerminalSession?
    private var connectionObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var fieldLabels: [NSTextField] = []

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

        remoteControls.orientation = .vertical
        remoteControls.alignment = .leading
        remoteControls.spacing = 6
        for button in [reconnectButton, controlButton, detachButton] {
            button.bezelStyle = .rounded
            button.target = self
            remoteControls.addArrangedSubview(button)
        }
        reconnectButton.action = #selector(reconnectSession)
        controlButton.action = #selector(takeControl)
        detachButton.action = #selector(detachSession)
        remoteControls.isHidden = true
        let stack = NSStackView(views: [fields, statusDetail, remoteControls])
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
        languageObservation = NotificationCenter.default.publisher(for: AppLocalization.didChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.refreshLabels()
                if let project = self.project { self.configure(project: project) }
            }
        refreshLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(project: Project) {
        if case .shared(let host, let directory) = project.location {
            self.project = project
            if observedSession !== project.selectedSession {
                observedSession = project.selectedSession
                connectionObservation = project.selectedSession?.$remoteStatus.receive(on: DispatchQueue.main)
                    .sink { [weak self] in self?.refreshSharedStatus($0) }
            }
            hostValue.stringValue = host.name
            switch try? host.endpoint() {
            case .ssh(let endpoint):
                userValue.stringValue = endpoint.user ?? "—"
                portValue.stringValue = endpoint.port.map(String.init) ?? "—"
            case .tailscale(_, let port):
                userValue.stringValue = "Tailscale"
                portValue.stringValue = String(port)
            case nil:
                userValue.stringValue = "—"
                portValue.stringValue = "—"
            }
            directoryValue.stringValue = directory
            hostValue.toolTip = host.address
            directoryValue.toolTip = directory
            remoteControls.isHidden = false
            refreshSharedStatus(project.selectedSession?.remoteStatus)
            return
        }
        guard case .ssh(let endpoint, let remoteDirectory, _, _) = project.location else {
            return
        }
        remoteControls.isHidden = true
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

    private func refreshLabels() {
        let titles = [String(localized: "Status"), String(localized: "Host"), String(localized: "User"),
                      String(localized: "Port"), String(localized: "Remote Directory")]
        for (label, title) in zip(fieldLabels, titles) { label.stringValue = title }
        reconnectButton.title = String(localized: "Reconnect")
        controlButton.title = String(localized: "Take Terminal Control")
        detachButton.title = String(localized: "Detach Remote Session")
    }

    private func refreshSharedStatus(_ status: RemoteRelayStatus?) {
        statusValue.stringValue = status?.label ?? String(localized: "Connecting…")
        statusValue.textColor = status?.state == .connected ? .systemGreen : .secondaryLabelColor
        let isActive = project?.selectedSession?.remoteConnection?.isActiveClient == true
        if status?.state == .connected {
            let control = isActive
                ? String(localized: "This client controls terminal input and size.")
                : String(localized: "Another client controls terminal input and size.")
            statusDetail.stringValue = String(localized: "Connected clients: \(status?.clients ?? 0)") + "\n" + control
        } else {
            statusDetail.stringValue = status?.message ?? ""
        }
        statusDetail.isHidden = false
        let exited = project?.selectedSession?.hasExited == true
        reconnectButton.isEnabled = !exited
        controlButton.isEnabled = !exited && status?.state == .connected && !isActive
        detachButton.isEnabled = !exited && status?.state != .detached
    }

    @objc private func reconnectSession() { project?.selectedSession?.remoteConnection?.reconnect() }
    @objc private func takeControl() { project?.selectedSession?.remoteConnection?.takeControl() }
    @objc private func detachSession() { project?.selectedSession?.remoteConnection?.detach() }

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
        fieldLabels.append(label)
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
