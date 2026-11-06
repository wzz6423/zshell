import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

@MainActor
final class BrowserWebExtensionManager: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = BrowserWebExtensionManager()
    private var store: BrowserWebExtensionStore?
    private var panel: NSPanel?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton()
    private let enableButton = NSButton()
    private let permissionsButton = NSButton()
    private let removeButton = NSButton()
    private var observation: AnyCancellable?
    private var installing = false
    private var options: NSPanel?
    private var optionsRuntime: BrowserWebExtensionRuntime?
    private var optionsContext: WKWebExtensionContext?

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localize), name: AppLocalization.didChange, object: nil)
    }

    func show(store: BrowserWebExtensionStore? = nil, relativeTo window: NSWindow? = nil) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: window) else { return }
        let store = store ?? .shared
        if panel == nil { configure() }
        guard let panel else { return }
        self.store = store
        observation = store.$entries.combineLatest(store.$error).sink { [weak self] _, error in
            self?.table.reloadData()
            self?.status.stringValue = error ?? ""
            self?.updateButtons()
        }
        localize()
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
    }

    private func configure() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 500, height: 340)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        guard let content = panel.contentView else { return }
        table.headerView = nil
        table.rowHeight = 34
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notice.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        for (button, action) in [(installButton, #selector(install)), (enableButton, #selector(toggleEnabled)),
                                 (permissionsButton, #selector(showPermissions)), (removeButton, #selector(remove))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let actions = NSStackView(views: [installButton, enableButton, permissionsButton, removeButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        for view in [notice, scroll, status, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            notice.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            notice.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: notice.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: notice.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: notice.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: notice.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: notice.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: notice.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    @objc private func localize() {
        panel?.title = String(localized: "Browser Extensions")
        table.setAccessibilityLabel(String(localized: "Browser Extensions"))
        installButton.title = String(localized: "Install Extension…")
        permissionsButton.title = String(localized: "Permissions…")
        removeButton.title = String(localized: "Remove")
        notice.stringValue = String(localized: "Install compatible WebExtensions from a directory or ZIP. Use the page’s Extensions menu for actions. Reload open pages after changes.")
        updateButtons()
        table.reloadData()
    }

    private var selected: BrowserWebExtensionStore.Entry? {
        guard let entries = store?.entries, entries.indices.contains(table.selectedRow) else { return nil }
        return entries[table.selectedRow]
    }

    private func updateButtons() {
        installButton.isEnabled = !installing && (store?.entries.count ?? 0) < 32
        enableButton.isEnabled = selected != nil && !installing
        enableButton.title = selected?.isEnabled == true ? String(localized: "Disable Extension") : String(localized: "Enable Extension")
        permissionsButton.isEnabled = selected != nil && !installing
        removeButton.isEnabled = selected != nil && !installing
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store?.entries.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = store?.entries[row] else { return nil }
        let label = NSTextField(labelWithString: entry.name + (entry.version.isEmpty ? "" : " · " + entry.version))
        label.lineBreakMode = .byTruncatingTail
        label.textColor = entry.isEnabled ? .labelColor : .secondaryLabelColor
        label.setAccessibilityValue(entry.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        return label
    }

    @objc private func install() {
        guard let store, let panel, !installing else { return }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = true
        chooser.allowsMultipleSelection = false
        chooser.allowedContentTypes = [.zip]
        chooser.prompt = String(localized: "Open")
        installing = true
        updateButtons()
        chooser.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let source = chooser.url else { self.installing = false; self.updateButtons(); return }
            Task { @MainActor in
                defer { self.installing = false; self.updateButtons() }
                do {
                    let (entry, _) = try await store.prepare(source)
                    guard panel.isVisible else { store.discard(entry); return }
                    let alert = Self.permissionAlert(name: entry.name, details: entry.permissions + entry.websites, installing: true)
                    let answer = await withCheckedContinuation { continuation in
                        alert.beginSheetModal(for: panel) { continuation.resume(returning: $0) }
                    }
                    if answer == .alertFirstButtonReturn {
                        do { try store.install(entry) }
                        catch { store.discard(entry); throw error }
                    } else { store.discard(entry) }
                } catch { self.report(error, store: store) }
            }
        }
    }

    @objc private func toggleEnabled() {
        guard let store, let entry = selected else { return }
        do { try store.setEnabled(!entry.isEnabled, id: entry.id) }
        catch { report(error, store: store) }
    }

    @objc private func remove() {
        guard let store, let entry = selected, !installing else { return }
        installing = true
        updateButtons()
        Task { @MainActor in
            defer { installing = false; updateButtons() }
            do { try await store.remove(id: entry.id) }
            catch { report(error, store: store) }
        }
    }

    @objc private func showPermissions() {
        guard let panel, let entry = selected else { return }
        let alert = Self.permissionAlert(name: entry.name, details: entry.permissions + entry.websites, installing: false)
        alert.buttons[0].title = String(localized: "Close")
        alert.buttons.dropFirst().forEach { $0.isHidden = true }
        alert.beginSheetModal(for: panel)
    }

    static func permissionAlert(name: String, details: [String], installing: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = name
        alert.informativeText = String(localized: "This extension can use the listed APIs and read or change pages on the listed websites. With activeTab, it can read or change the current page when you invoke its action. Only install extensions you trust.")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.string = details.isEmpty ? String(localized: "No website or API permissions requested.") : details.joined(separator: "\n")
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: installing ? String(localized: "Install") : String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    func report(_ error: Error, store: BrowserWebExtensionStore) {
        store.report(error)
    }

    func showOptions(_ context: WKWebExtensionContext, relativeTo window: NSWindow?, runtime: BrowserWebExtensionRuntime) {
        guard let host = AppWindowPresentation.hostWindow(relativeTo: window), let url = context.optionsPageURL,
              let configuration = context.webViewConfiguration else { return }
        options?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.title = context.webExtension.displayName ?? String(localized: "Options")
        let webView = WKWebView(frame: panel.contentView?.bounds ?? .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(webView)
        webView.load(URLRequest(url: url))
        options = panel
        optionsRuntime = runtime
        optionsContext = context
        AppWindowPresentation.attach(panel, to: host, placement: .centered)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === panel { observation = nil }
        if notification.object as? NSWindow === options {
            options?.contentView?.subviews.compactMap { $0 as? WKWebView }.forEach { $0.stopLoading(); $0.removeFromSuperview() }
            options = nil
            optionsRuntime = nil
            optionsContext = nil
        }
    }

    func closeOptions(for context: WKWebExtensionContext) {
        if optionsContext === context { options?.close() }
    }
}
