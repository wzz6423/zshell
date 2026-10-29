import AppKit
import WebKit

@MainActor
final class BrowserProfileImportController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = BrowserProfileImportController()
    private let profilePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cookiesButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let historyButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sessionsButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let previewButton = NSButton()
    private let importButton = NSButton()
    private let closeButton = NSButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previewText = NSTextView()
    private var panel: NSPanel?
    private weak var manager: TerminalManager?
    private var profiles: [BrowserProfile] = []
    private var prepared: BrowserProfilePreview?
    private var revision = 0
    private var busy = false
    private var lastSummary: String?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localize), name: AppLocalization.didChange, object: nil)
    }

    func installMenu(in mainMenu: NSMenu) {
        guard let browser = mainMenu.items.first(where: { $0.title == String(localized: "Browser") })?.submenu else { return }
        let commands: [(String, String, Selector)] = [
            ("browser-profile-import", String(localized: "Import Browser Data…"), #selector(showImport(_:))),
            ("browser-imported-history", String(localized: "Imported Browser History"), #selector(showHistory(_:))),
        ]
        for (id, title, action) in commands {
            let identifier = NSUserInterfaceItemIdentifier(id)
            let item = browser.items.first { $0.identifier == identifier } ?? NSMenuItem(title: title, action: action, keyEquivalent: "")
            if item.identifier != identifier { item.identifier = identifier }
            if item.title != title { item.title = title }
            if item.action != action { item.action = action }
            if item.target !== self { item.target = self }
            if item.menu == nil { browser.addItem(item) }
        }
    }

    @objc private func showImport(_ sender: Any?) {
        guard let manager = TerminalManager.activeWindowManager,
              let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        self.manager = manager
        revision += 1
        prepared = nil
        lastSummary = nil
        previewText.string = ""
        status.stringValue = ""
        profiles = []
        profilePopUp.removeAllItems()
        localize()
        setBusy(true)
        let current = revision
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { BrowserProfileData.discover(home: home) }.value
            guard let self, self.revision == current else { return }
            self.profiles = found.profiles
            self.profilePopUp.addItems(withTitles: found.profiles.map { "\($0.browserName) — \($0.name)" })
            if !found.errors.isEmpty { self.status.stringValue = found.errors.joined(separator: "\n") }
            else if found.profiles.isEmpty { self.status.stringValue = String(localized: "No supported browser profiles were found.") }
            self.setBusy(false)
        }
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func showHistory(_ sender: Any?) {
        guard let manager = TerminalManager.activeWindowManager else { return }
        BrowserImportedHistoryController.shared.show(manager: manager)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { TerminalManager.activeWindowManager != nil }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 430)
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        profilePopUp.target = self
        profilePopUp.action = #selector(selectionChanged(_:))
        for button in [cookiesButton, historyButton, sessionsButton] {
            button.state = .on
            button.target = self
            button.action = #selector(selectionChanged(_:))
        }
        let categories = NSStackView(views: [cookiesButton, historyButton, sessionsButton])
        categories.orientation = .horizontal
        categories.spacing = 16
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 0
        status.maximumNumberOfLines = 0
        status.textColor = .secondaryLabelColor
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.font = .systemFont(ofSize: 12)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true
        previewText.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = previewText
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        previewButton.target = self
        previewButton.action = #selector(preview(_:))
        importButton.target = self
        importButton.action = #selector(importSelected(_:))
        importButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.keyEquivalent = "\u{1b}"
        for button in [previewButton, importButton, closeButton] { button.bezelStyle = .rounded }
        let actions = NSStackView(views: [previewButton, NSView(), closeButton, importButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        for view in [profilePopUp, categories, explanation, scroll, status, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            profilePopUp.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            profilePopUp.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            profilePopUp.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            categories.topAnchor.constraint(equalTo: profilePopUp.bottomAnchor, constant: 12),
            categories.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            categories.trailingAnchor.constraint(lessThanOrEqualTo: profilePopUp.trailingAnchor),
            explanation.topAnchor.constraint(equalTo: categories.bottomAnchor, constant: 12),
            explanation.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: profilePopUp.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: profilePopUp.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: profilePopUp.trailingAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            status.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: profilePopUp.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    @objc private func localize() {
        panel?.title = String(localized: "Browser Data Import")
        profilePopUp.setAccessibilityLabel(String(localized: "Browser profile"))
        cookiesButton.title = String(localized: "Cookies")
        historyButton.title = String(localized: "History")
        sessionsButton.title = String(localized: "Open Tabs")
        previewButton.title = String(localized: "Preview")
        importButton.title = String(localized: "Import")
        closeButton.title = String(localized: "Close")
        previewText.setAccessibilityLabel(String(localized: "Import Preview"))
        explanation.stringValue = String(localized: "Import stays on this Mac. Matching cookies may be replaced. Local storage and tab navigation history are not imported.")
        if let prepared { render(prepared) }
    }

    private var selection: BrowserProfileSelection {
        var value: BrowserProfileSelection = []
        if cookiesButton.state == .on { value.insert(.cookies) }
        if historyButton.state == .on { value.insert(.history) }
        if sessionsButton.state == .on { value.insert(.sessions) }
        return value
    }

    private var selectedProfile: BrowserProfile? {
        profiles.indices.contains(profilePopUp.indexOfSelectedItem) ? profiles[profilePopUp.indexOfSelectedItem] : nil
    }

    private func setBusy(_ value: Bool) {
        busy = value
        profilePopUp.isEnabled = !value && !profiles.isEmpty
        for button in [cookiesButton, historyButton, sessionsButton] { button.isEnabled = !value }
        previewButton.isEnabled = !value && selectedProfile != nil && !selection.isEmpty
        importButton.isEnabled = !value && prepared != nil && selectedProfile != nil && !selection.isEmpty
    }

    @objc private func selectionChanged(_ sender: Any?) {
        revision += 1
        prepared = nil
        lastSummary = nil
        previewText.string = ""
        status.stringValue = ""
        setBusy(false)
    }

    @objc private func preview(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        revision += 1
        let current = revision
        let categories = selection
        prepared = nil
        lastSummary = nil
        status.stringValue = String(localized: "Reading browser data…")
        setBusy(true)
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                BrowserProfileData.preview(profile, selection: categories)
            }.value
            guard let self, self.revision == current else { return }
            self.prepared = data
            self.render(data)
            self.status.stringValue = String(localized: "Review the preview, then choose Import.")
            self.setBusy(false)
        }
    }

    private func render(_ preview: BrowserProfilePreview) {
        var lines: [String] = []
        if selection.contains(.cookies) {
            lines.append(String(localized: "Cookies: \(preview.cookieCount)"))
            if let error = preview.cookieError { lines.append(error) }
            else { lines.append(contentsOf: preview.cookieDomains.map { "  " + $0 }) }
            if let warning = preview.cookieWarning { lines.append(warning) }
        }
        if selection.contains(.history) {
            lines.append(String(localized: "History: \(preview.history.total)"))
            if let error = preview.history.error { lines.append(error) }
            lines.append(contentsOf: preview.history.values.prefix(5).map { "  " + ($0.title.isEmpty ? $0.url : "\($0.title) — \($0.url)") })
        }
        if selection.contains(.sessions) {
            lines.append(String(localized: "Open tabs: \(preview.sessions.total)"))
            if let error = preview.sessions.error { lines.append(error) }
            lines.append(contentsOf: preview.sessions.values.prefix(5).map { "  " + ($0.title.isEmpty ? $0.url : "\($0.title) — \($0.url)") })
        }
        if let lastSummary { lines.append(""); lines.append(lastSummary) }
        previewText.string = lines.joined(separator: "\n")
    }

    @objc private func importSelected(_ sender: Any?) {
        guard let profile = selectedProfile, let prepared, let manager else { return }
        revision += 1
        let current = revision
        let categories = selection
        let project = manager.selectedProject
        status.stringValue = String(localized: "Importing…")
        setBusy(true)
        Task { [weak self, weak manager, weak project] in
            var results: [String] = []
            if categories.contains(.cookies), prepared.cookieError == nil {
                let cookies = await Task.detached(priority: .userInitiated) { BrowserProfileData.cookies(profile) }.value
                guard let self, self.revision == current else { return }
                var attempted: [HTTPCookie] = []
                var identities = Set<String>()
                var skipped = cookies.skipped
                let store = WKWebsiteDataStore.default().httpCookieStore
                for (index, item) in cookies.values.enumerated() {
                    guard self.revision == current else { return }
                    if index % 32 == 0 { await Task.yield() }
                    let host = item.domain.hasPrefix(".") ? String(item.domain.dropFirst()) : item.domain
                    guard let url = URL(string: "\(item.secure ? "https" : "http")://\(host)/"),
                          BrowserImportedPage.safeURL(url.absoluteString),
                          item.expires == -1 || item.expires > Date().timeIntervalSince1970 else { skipped += 1; continue }
                    let value: ZshellJSONValue = .object([
                        "name": .string(item.name), "value": .string(item.value), "domain": .string(item.domain),
                        "path": .string(item.path), "expires": .number(item.expires), "httpOnly": .bool(item.httpOnly),
                        "secure": .bool(item.secure), "sameSite": .string(item.sameSite),
                    ])
                    guard let cookie = try? BrowserStorageState.decodeCookie(value, for: url) else { skipped += 1; continue }
                    let identity = "\(cookie.domain.lowercased())\n\(cookie.path)\n\(cookie.name)"
                    guard identities.insert(identity).inserted else { skipped += 1; continue }
                    await withCheckedContinuation { continuation in store.setCookie(cookie) { continuation.resume() } }
                    attempted.append(cookie)
                }
                let actual: [HTTPCookie] = await withCheckedContinuation { continuation in
                    store.getAllCookies { continuation.resume(returning: $0) }
                }
                guard self.revision == current else { return }
                let stored = Dictionary(actual.map { ("\($0.domain.lowercased())\n\($0.path)\n\($0.name)", $0.value) },
                                        uniquingKeysWith: { _, newer in newer })
                let imported = attempted.filter { stored["\($0.domain.lowercased())\n\($0.path)\n\($0.name)"] == $0.value }.count
                skipped += attempted.count - imported
                results.append(String(localized: "Cookies imported: \(imported), skipped: \(skipped)"))
                if let error = cookies.error { results.append(error) }
            } else if categories.contains(.cookies), let error = prepared.cookieError { results.append(error) }
            guard let self, self.revision == current, let manager else { return }
            if categories.contains(.history) {
                if let error = prepared.history.error { results.append(error) }
                if prepared.history.error == nil || !prepared.history.values.isEmpty {
                    do {
                        let saved = try BrowserImportedHistoryStore.merge(prepared.history.values)
                        let skipped = saved.skipped + prepared.history.skipped
                        results.append(String(localized: "History imported: \(saved.saved), skipped: \(skipped)"))
                    } catch { results.append(error.localizedDescription) }
                }
            }
            if categories.contains(.sessions) {
                if let error = prepared.sessions.error { results.append(error) }
                let pages = Array(prepared.sessions.values.prefix(100))
                if !pages.isEmpty {
                    let destination = project.flatMap { candidate in manager.projects.contains(where: { $0 === candidate }) ? candidate : nil }
                        ?? (project == nil ? manager.selectedProject ?? manager.newProject() : nil)
                    if let destination {
                        for page in pages.reversed() { destination.newBrowserTab(initialURL: page.url, initialFocus: .none, focus: false) }
                        let count = pages.count
                        let skipped = prepared.sessions.values.count - count + prepared.sessions.skipped
                        results.append(String(localized: "Tabs opened: \(count), skipped: \(skipped)"))
                    } else { results.append(String(localized: "The destination project is no longer available.")) }
                } else {
                    let count = 0
                    let skipped = prepared.sessions.skipped
                    results.append(String(localized: "Tabs opened: \(count), skipped: \(skipped)"))
                }
            }
            self.lastSummary = results.joined(separator: "\n")
            self.render(prepared)
            self.status.stringValue = String(localized: "Import finished. Review any skipped items or errors above.")
            self.prepared = nil
            self.setBusy(false)
        }
    }

    @objc private func close(_ sender: Any?) { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        revision += 1
        if let panel { panel.parent?.removeChildWindow(panel) }
        manager = nil
        setBusy(false)
    }
}
