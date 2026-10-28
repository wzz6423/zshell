import AppKit
import Combine

final class SettingsBrowserPane: SettingsPaneViewController, NSTextViewDelegate {
    private let enabledSwitch = SettingsSwitch { AppSettings.shared.browserContentBlocking = $0 }
    private let easyListSwitch = SettingsSwitch { _ in }
    private let easyPrivacySwitch = SettingsSwitch { _ in }
    private let customLists = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var isEditingLists = false
    private lazy var applyButton = SettingsActionButton(title: String(localized: "Apply Lists")) { [weak self] in self?.applyLists() }
    private lazy var updateButton = SettingsActionButton(title: String(localized: "Update Lists Now")) { BrowserContentBlocker.shared.refresh() }

    override func makeGroups() -> [NSView] {
        easyListSwitch.target = self
        easyListSwitch.action = #selector(builtInChanged)
        easyPrivacySwitch.target = self
        easyPrivacySwitch.action = #selector(builtInChanged)
        customLists.isRichText = false
        customLists.isAutomaticQuoteSubstitutionEnabled = false
        customLists.isAutomaticDashSubstitutionEnabled = false
        customLists.isAutomaticSpellingCorrectionEnabled = false
        customLists.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        customLists.textContainerInset = NSSize(width: 6, height: 6)
        customLists.isHorizontallyResizable = false
        customLists.textContainer?.widthTracksTextView = true
        customLists.delegate = self
        customLists.setAccessibilityLabel(String(localized: "Custom ABP list URLs"))
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = customLists
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        customLists.autoresizingMask = [.width]
        customLists.minSize = NSSize(width: 0, height: 110)
        customLists.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let explanation = NSTextField(wrappingLabelWithString: String(localized: "One HTTP or HTTPS ABP list URL per line. Up to 8 lists total. HTTP lists are unencrypted."))
        let limitations = NSTextField(wrappingLabelWithString: String(localized: "Supports common network and CSS hiding filters. Scriptlets, procedural filters, redirects, regular expressions, and complex domain exceptions are skipped. This is not full uBlock Origin compatibility."))
        for label in [explanation, limitations, statusLabel, validationLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        let editor = NSStackView(views: [explanation, scroll, validationLabel, applyButton])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 8
        for view in [explanation, scroll, validationLabel] { view.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true }
        let status = NSStackView(views: [statusLabel, updateButton, limitations])
        status.orientation = .vertical
        status.alignment = .leading
        status.spacing = 8
        for label in [statusLabel, limitations] { label.widthAnchor.constraint(equalTo: status.widthAnchor).isActive = true }
        observe(BrowserContentBlocker.shared.$status.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncFromSettings() })
        return [
            SettingsGroup(rows: [
                SettingsRow(title: String(localized: "Block ads and trackers"), description: String(localized: "Applies to future page requests in every browser pane. Reload open pages after changing rules."), control: enabledSwitch, symbolName: "hand.raised.fill"),
                SettingsCustomRow(status),
            ]),
            SettingsGroup(header: String(localized: "Filter Lists"), rows: [
                SettingsRow(title: "EasyList", control: easyListSwitch),
                SettingsRow(title: "EasyPrivacy", control: easyPrivacySwitch),
                SettingsCustomRow(editor),
            ]),
        ]
    }

    override func syncFromSettings() {
        enabledSwitch.isOn = settings.browserContentBlocking
        let lists = settings.browserFilterLists.split(whereSeparator: \.isNewline).map(String.init)
        easyListSwitch.isOn = lists.contains(BrowserFilterSource.catalog[0].url.absoluteString)
        easyPrivacySwitch.isOn = lists.contains(BrowserFilterSource.catalog[1].url.absoluteString)
        if !isEditingLists {
            customLists.string = lists.filter { url in !BrowserFilterSource.catalog.contains { $0.url.absoluteString == url } }.joined(separator: "\n")
        }
        statusLabel.stringValue = BrowserContentBlocker.shared.status.text
        updateButton.isEnabled = settings.browserContentBlocking && BrowserContentBlocker.shared.status != .updating
    }

    func textDidChange(_ notification: Notification) { isEditingLists = true }

    @objc private func builtInChanged() { applyLists() }

    private func applyLists() {
        var urls = customLists.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if easyListSwitch.isOn { urls.insert(BrowserFilterSource.catalog[0].url.absoluteString, at: 0) }
        if easyPrivacySwitch.isOn { urls.append(BrowserFilterSource.catalog[1].url.absoluteString) }
        let text = urls.joined(separator: "\n")
        do {
            let sources = try BrowserFilterSource.parse(text)
            isEditingLists = false
            validationLabel.isHidden = true
            settings.browserFilterLists = sources.map { $0.url.absoluteString }.joined(separator: "\n")
        } catch {
            isEditingLists = true
            validationLabel.stringValue = String(localized: "Enter valid HTTP or HTTPS URLs without credentials or fragments, with at most 8 lists total.")
            validationLabel.isHidden = false
        }
    }
}
