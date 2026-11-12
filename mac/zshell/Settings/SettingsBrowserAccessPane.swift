import AppKit
import Combine

final class SettingsBrowserAccessPane: SettingsPaneViewController, NSTextFieldDelegate {
    private let access = BrowserAccessController.shared
    private let enabledSwitch = SettingsSwitch { AppSettings.shared.browserAccessEnabled = $0 }
    private let interfacePicker = NSPopUpButton()
    private let portField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let addressLabel = NSTextField(wrappingLabelWithString: "")
    private let fingerprintLabel = NSTextField(wrappingLabelWithString: "")
    private let pendingStack = NSStackView()
    private let clientsStack = NSStackView()
    private var pendingIDs: [UUID] = []
    private var clientIDs: [UUID] = []
    private var interfaceIDs: [String] = []
    private var networkGroup: SettingsGroup?
    private var pairingGroup: SettingsGroup?
    private var clientsGroup: SettingsGroup?
    private var certificateGroup: SettingsGroup?
    private lazy var openButton = SettingsActionButton(title: String(localized: "Open Local Access Page")) { [weak self] in
        if let url = self?.access.localURL { NSWorkspace.shared.open(url) }
    }
    private lazy var openRemoteButton = SettingsActionButton(title: String(localized: "Open Private Network Page")) { [weak self] in
        if let url = self?.access.remoteURL { NSWorkspace.shared.open(url) }
    }
    private lazy var exportButton = SettingsActionButton(title: String(localized: "Export TLS Certificate…")) { [weak self] in self?.access.exportCertificate() }
    private lazy var revokeButton = SettingsActionButton(title: String(localized: "Revoke All Clients")) { [weak self] in self?.access.revoke(nil) }

    override func makeGroups() -> [NSView] {
        interfacePicker.controlSize = .small
        interfacePicker.target = self
        interfacePicker.action = #selector(interfaceChanged)
        interfacePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        portField.delegate = self
        portField.alignment = .right
        portField.controlSize = .small
        portField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1024
        formatter.maximum = 65_535
        formatter.allowsFloats = false
        portField.formatter = formatter
        for label in [statusLabel, addressLabel, fingerprintLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.isSelectable = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        fingerprintLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let explanation = NSTextField(wrappingLabelWithString: String(localized:
            "Access this Mac’s terminal panes from a browser. New local panes become available after enabling. Existing panes keep their current process."))
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let main = SettingsGroup(rows: [
            SettingsRow(title: String(localized: "Enable browser access"), control: enabledSwitch, symbolName: "network"),
            SettingsCustomRow(explanation), SettingsCustomRow(statusLabel), SettingsButtonRow(title: String(localized: "Retry")) { [weak self] in self?.access.retry() },
        ])
        let network = SettingsGroup(header: String(localized: "Private Network"), rows: [
            SettingsRow(title: String(localized: "Listen on"), control: interfacePicker),
            SettingsRow(title: String(localized: "HTTPS port"), control: portField),
            SettingsCustomRow(addressLabel), SettingsCustomRow(openButton), SettingsCustomRow(openRemoteButton),
        ])
        networkGroup = network
        let trust = NSTextField(wrappingLabelWithString: String(localized:
            "Before pairing remotely, compare the TLS certificate fingerprint on this Mac and trust that certificate on your client device."))
        trust.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        trust.textColor = .secondaryLabelColor
        trust.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let certificates = SettingsGroup(header: String(localized: "TLS Certificate"), rows: [
            SettingsCustomRow(trust), SettingsCustomRow(fingerprintLabel), SettingsCustomRow(exportButton),
        ])
        certificateGroup = certificates
        for stack in [pendingStack, clientsStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
        }
        let pairing = SettingsGroup(header: String(localized: "Pairing Requests"), rows: [SettingsCustomRow(pendingStack)])
        pairingGroup = pairing
        let clients = SettingsGroup(header: String(localized: "Authorized Clients"), rows: [SettingsCustomRow(clientsStack), SettingsCustomRow(revokeButton)])
        clientsGroup = clients
        observe(access.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncFromSettings() })
        return [main, network, certificates, pairing, clients]
    }

    override func syncFromSettings() {
        enabledSwitch.isOn = settings.browserAccessEnabled
        let values = access.interfaces.map(\.id)
        if interfaceIDs != values {
            interfaceIDs = values
            interfacePicker.removeAllItems()
            for interface in access.interfaces {
                interfacePicker.addItem(withTitle: interface.isLoopback ? String(localized: "Localhost Only")
                    : (interface.isTailscale ? "Tailscale" : String(localized: "LAN"))
                        + " · " + interface.name + " · " + interface.address)
            }
        }
        if let index = interfaceIDs.firstIndex(of: settings.browserAccessInterface) { interfacePicker.selectItem(at: index) }
        else { interfacePicker.select(nil) }
        if portField.currentEditor() == nil { portField.stringValue = String(settings.browserAccessPort) }
        networkGroup?.isHidden = !settings.browserAccessEnabled
        networkGroup?.setRowHidden(settings.browserAccessInterface == "loopback", at: 1)
        addressLabel.stringValue = access.remoteURL?.absoluteString ?? access.localURL?.absoluteString ?? ""
        openButton.isEnabled = access.localURL != nil
        openRemoteButton.isHidden = access.remoteURL == nil
        if let error = access.error {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = access.isStarting ? String(localized: "Starting browser access…")
                : access.localURL != nil ? String(localized: "Browser access is running. Approve only clients you trust to operate this Mac.")
                : String(localized: "Browser access is off.")
            statusLabel.textColor = .secondaryLabelColor
        }
        fingerprintLabel.stringValue = access.fingerprint ?? ""
        certificateGroup?.isHidden = !settings.browserAccessEnabled || access.remoteURL == nil
        exportButton.isEnabled = access.certificate != nil
        updateClients()
        pairingGroup?.isHidden = !settings.browserAccessEnabled || access.pending.isEmpty
        clientsGroup?.isHidden = access.clients.isEmpty
        revokeButton.isEnabled = !access.clients.isEmpty
    }

    private func updateClients() {
        if pendingIDs != access.pending.map(\.id) {
            pendingIDs = access.pending.map(\.id)
            clear(pendingStack)
            for pending in access.pending {
                let row = clientRow(name: pending.name, detail: pending.origin + " · " + pending.address + " · " + pending.code,
                    buttons: [SettingsActionButton(title: String(localized: "Approve")) { [weak self] in self?.access.approve(pending.id) },
                              SettingsActionButton(title: String(localized: "Deny")) { [weak self] in self?.access.deny(pending.id) }])
                pendingStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: pendingStack.widthAnchor).isActive = true
            }
        }
        if clientIDs != access.clients.map(\.id) {
            clientIDs = access.clients.map(\.id)
            clear(clientsStack)
            for client in access.clients {
                let row = clientRow(name: client.name, detail: client.origin + " · " + client.address,
                    buttons: [SettingsActionButton(title: String(localized: "Revoke")) { [weak self] in self?.access.revoke(client.id) }])
                clientsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: clientsStack.widthAnchor).isActive = true
            }
        }
    }

    private func clientRow(name: String, detail: String, buttons: [NSButton]) -> NSView {
        let label = NSTextField(wrappingLabelWithString: name)
        let subtitle = NSTextField(wrappingLabelWithString: detail)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.isSelectable = true
        for label in [label, subtitle] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let text = NSStackView(views: [label, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        for label in [label, subtitle] { label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        return SettingsStackRow(views: [text] + buttons)
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    @objc private func interfaceChanged() {
        let index = interfacePicker.indexOfSelectedItem
        guard interfaceIDs.indices.contains(index) else { return }
        settings.browserAccessInterface = interfaceIDs[index]
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (1024...65_535).contains(portField.integerValue) { settings.browserAccessPort = portField.integerValue }
        else { portField.stringValue = String(settings.browserAccessPort) }
    }
}
