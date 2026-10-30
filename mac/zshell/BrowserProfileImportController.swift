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
    private let accessButton = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previewText = NSTextView()
    private var panel: NSPanel?
    private weak var manager: TerminalManager?
    private var profiles: [BrowserProfile] = []
    private var blocked: [BrowserProfile.Kind] = []
    private var requested = Set<BrowserProfile.Kind>()
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
        guard let manager = TerminalManager.activeWindowManager else { return }
        show(for: manager)
    }

    func show(for manager: TerminalManager) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: manager.presentationWindow) else { return }
        if panel == nil { configure() }
        guard let panel else { return }
        self.manager = manager
        revision += 1
        prepared = nil
        lastSummary = nil
        previewText.string = ""
        requested = []
        localize()
        reloadProfiles()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
    }

    private func reloadProfiles() {
        revision += 1
        // The popup is rebuilt and resets to the first profile, so a preview
        // of the previous selection must not feed the next import.
        prepared = nil
        lastSummary = nil
        previewText.string = ""
        status.stringValue = ""
        profiles = []
        blocked = []
        profilePopUp.removeAllItems()
        setBusy(true)
        let current = revision
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { BrowserProfileData.discover(home: home) }.value
            guard let self, self.revision == current else { return }
            self.profiles = found.profiles
            self.blocked = found.blocked
            self.profilePopUp.addItems(withTitles: found.profiles.map { "\($0.browserName) — \($0.name)" })
            self.status.stringValue = self.discoveryStatus
            self.setBusy(false)
        }
    }

    private var discoveryStatus: String {
        let pending = blocked.filter { !requested.contains($0) }
        if !pending.isEmpty {
            let names = pending.map(\.browserName).formatted()
            return String(localized: "To read \(names) data, choose Allow Access, then Open.")
        }
        if !blocked.isEmpty {
            let names = blocked.map(\.browserName).formatted()
            return String(localized: "macOS still blocks \(names) data. Allow zshell in System Settings › Privacy & Security › Full Disk Access, then reopen this window.")
        }
        return profiles.isEmpty ? String(localized: "No supported browser profiles were found.") : ""
    }

    // A folder the user picks in the system open panel is the only per-app grant macOS offers for
    // protected browser data; without it, only Full Disk Access lets zshell list the profiles.
    @objc private func requestAccess(_ sender: Any?) {
        guard let panel, let kind = blocked.first(where: { !requested.contains($0) }) ?? blocked.first else { return }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.directoryURL = kind.root(home: FileManager.default.homeDirectoryForCurrentUser)
        open.message = String(localized: "Choose Open to let zshell read \(kind.browserName) data.")
        open.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .OK else { return }
            self.requested.insert(kind)
            self.reloadProfiles()
        }
    }

    @objc private func showHistory(_ sender: Any?) {
        guard let manager = TerminalManager.activeWindowManager else { return }
        BrowserImportedHistoryController.shared.show(manager: manager)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { TerminalManager.activeWindowManager != nil }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 600, height: 360)
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
        categories.setContentCompressionResistancePriority(.required, for: .horizontal)
        categories.setHuggingPriority(.required, for: .horizontal)
        profilePopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        profilePopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.maximumNumberOfLines = 0
        status.textColor = .secondaryLabelColor
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.font = .systemFont(ofSize: 12)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.frame = NSRect(x: 0, y: 0, width: 660, height: 300)
        previewText.minSize = NSSize(width: 0, height: 0)
        previewText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        accessButton.target = self
        accessButton.action = #selector(requestAccess(_:))
        accessButton.isHidden = true
        for button in [previewButton, accessButton, importButton, closeButton] { button.bezelStyle = .rounded }
        let actions = NSStackView(views: [previewButton, accessButton, NSView(), closeButton, importButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        for view in [profilePopUp, categories, scroll, status, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            profilePopUp.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            profilePopUp.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            profilePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            categories.centerYAnchor.constraint(equalTo: profilePopUp.centerYAnchor),
            categories.leadingAnchor.constraint(equalTo: profilePopUp.trailingAnchor, constant: 16),
            categories.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: profilePopUp.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: categories.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: categories.trailingAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            status.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: profilePopUp.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: categories.trailingAnchor),
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
        accessButton.title = String(localized: "Allow Access")
        previewText.setAccessibilityLabel(String(localized: "Import Preview"))
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
        accessButton.isHidden = blocked.isEmpty
        accessButton.isEnabled = !value
        for button in [cookiesButton, historyButton, sessionsButton] { button.isEnabled = !value }
        previewButton.isEnabled = !value && selectedProfile != nil && !selection.isEmpty
        importButton.isEnabled = !value && prepared != nil && selectedProfile != nil && !selection.isEmpty
    }

    @objc private func selectionChanged(_ sender: Any?) {
        revision += 1
        prepared = nil
        lastSummary = nil
        previewText.string = ""
        status.stringValue = discoveryStatus
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
            self.status.stringValue = self.discoveryStatus
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
        let destination: Project? = if categories.contains(.cookies) || categories.contains(.sessions) {
            manager.selectedProject ?? manager.newProject()
        } else { manager.selectedProject }
        // Pin the project and store before any suspension so switching or
        // closing the project never redirects credentials to its neighbor.
        let projectID = destination?.id
        let dataStore = categories.contains(.cookies) ? destination?.browserDataStore : nil
        let isRemote = destination?.isRemote == true
        status.stringValue = String(localized: "Importing…")
        setBusy(true)
        Task { [weak self, weak manager] in
            guard let self, self.revision == current else { return }
            var results: [String] = []
            @MainActor func hasDestination() -> Bool {
                guard self.revision == current else { return false }
                guard let projectID, manager?.projects.contains(where: { $0.id == projectID }) == true else {
                    self.finishImport(prepared, results: results + [String(localized: "The destination project is no longer available.")])
                    return false
                }
                return true
            }
            if categories.contains(.cookies), prepared.cookieError == nil, let dataStore {
                let cookies = await Task.detached(priority: .userInitiated) { BrowserProfileData.cookies(profile) }.value
                guard hasDestination() else { return }
                var attempted: [HTTPCookie] = []
                var identities = Set<String>()
                var skipped = cookies.skipped
                let store = dataStore.httpCookieStore
                for (index, item) in cookies.values.enumerated() {
                    if index % 32 == 0 { await Task.yield() }
                    guard hasDestination() else { return }
                    let host = item.domain.hasPrefix(".") ? String(item.domain.dropFirst()) : item.domain
                    let urlHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                    guard let url = URL(string: "\(item.secure ? "https" : "http")://\(urlHost)/"),
                          BrowserImportedPage.safeURL(url.absoluteString),
                          item.expires == -1 || item.expires > Date().timeIntervalSince1970 else { skipped += 1; continue }
                    var fields: [String: ZshellJSONValue] = [
                        "name": .string(item.name), "value": .string(item.value), "domain": .string(item.domain),
                        "path": .string(item.path), "expires": .number(item.expires), "httpOnly": .bool(item.httpOnly),
                        "secure": .bool(item.secure), "sameSite": .string(item.sameSite),
                    ]
                    guard var cookie = try? BrowserStorageState.decodeCookie(.object(fields), for: url) else { skipped += 1; continue }
                    let routedURL = isRemote ? BrowserRemoteRouting.routedURL(url) : url
                    if let routedHost = routedURL.host, routedHost != url.host {
                        fields["domain"] = .string((cookie.domain.hasPrefix(".") ? "." : "") + routedHost)
                        guard let routedCookie = try? BrowserStorageState.decodeCookie(.object(fields), for: routedURL) else { skipped += 1; continue }
                        cookie = routedCookie
                    }
                    let identity = "\(cookie.domain.lowercased())\n\(cookie.path)\n\(cookie.name)"
                    guard identities.insert(identity).inserted else { skipped += 1; continue }
                    await withCheckedContinuation { continuation in store.setCookie(cookie) { continuation.resume() } }
                    guard hasDestination() else { return }
                    attempted.append(cookie)
                }
                let actual: [HTTPCookie] = await withCheckedContinuation { continuation in
                    store.getAllCookies { continuation.resume(returning: $0) }
                }
                guard hasDestination() else { return }
                let stored = Dictionary(actual.map { ("\($0.domain.lowercased())\n\($0.path)\n\($0.name)", $0.value) },
                                        uniquingKeysWith: { _, newer in newer })
                let imported = attempted.filter { stored["\($0.domain.lowercased())\n\($0.path)\n\($0.name)"] == $0.value }.count
                skipped += attempted.count - imported
                results.append(String(localized: "Cookies imported: \(imported), skipped: \(skipped)"))
                if let error = cookies.error { results.append(error) }
            } else if categories.contains(.cookies), let error = prepared.cookieError { results.append(error) }
            guard self.revision == current, let manager else { return }
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
                    guard hasDestination() else { return }
                    if let destination = manager.projects.first(where: { $0.id == projectID }) {
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
            self.finishImport(prepared, results: results)
        }
    }

    private func finishImport(_ preview: BrowserProfilePreview, results: [String]) {
        lastSummary = results.joined(separator: "\n")
        render(preview)
        status.stringValue = discoveryStatus
        prepared = nil
        setBusy(false)
    }

    @objc private func close(_ sender: Any?) { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        revision += 1
        if let panel { panel.parent?.removeChildWindow(panel) }
        manager = nil
        setBusy(false)
    }
}
