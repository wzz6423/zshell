import AppKit
import Combine
import SwiftUI

/// SwiftUI only mounts the panel; AppKit owns its layout and update cadence.
struct SessionInfoPanel: NSViewRepresentable {
    @ObservedObject var model: SessionInfoModel
    let session: TerminalSession?
    let remoteProject: Project?
    let externalEditor: ExternalEditor
    let showsVimHints: Bool
    let fontScale: CGFloat

    func makeNSView(context: Context) -> SessionInfoPanelView {
        SessionInfoPanelView()
    }

    func updateNSView(_ view: SessionInfoPanelView, context: Context) {
        view.configure(model: model, session: session, remoteProject: remoteProject,
                       editor: externalEditor, showsVimHints: showsVimHints, fontScale: fontScale)
    }

    static func dismantleNSView(_ view: SessionInfoPanelView, coordinator: ()) {
        view.stopPolling()
    }
}

@MainActor
final class SessionInfoPanelView: NSView, NSSearchFieldDelegate {
    private let scroll = NSScrollView()
    private let content = InfoDocumentStack()
    private let information = NSStackView()
    private let hints = NSStackView()
    private let hintRows = NSStackView()
    private let hintSearch = NSSearchField()
    private let hintMode = NSTextField(labelWithString: "")
    private var hintHeading: NSButton!
    private weak var session: TerminalSession?
    private var timer: Timer?
    private var showsVimHints = false
    private var fontScale: CGFloat = 1
    private var accentColor: NSColor?
    private var mode: VimMode?
    private var foregroundPid: pid_t?
    private var collapsed: Set<String> = []
    private var renderInformation: (() -> Void)?
    private var informationSignature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        for stack in [content, information, hints, hintRows] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        scroll.documentView = content
        content.addArrangedSubview(information)
        content.addArrangedSubview(hints)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            information.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24),
            hints.widthAnchor.constraint(equalTo: information.widthAnchor),
        ])
        hints.isHidden = true
        hintHeading = button(String(localized: "VIM COMMANDS"), symbol: "chevron.down",
                             help: String(localized: "VIM COMMANDS")) { [weak self] in
            guard let self else { return }
            if self.collapsed.contains("vim") { self.collapsed.remove("vim") }
            else { self.collapsed.insert("vim") }
            self.rebuildHints()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshLanguage), name: AppLocalization.didChange, object: nil
        )
        hintSearch.placeholderString = String(localized: "Search Vim commands")
        hintSearch.setAccessibilityLabel(String(localized: "Search Vim commands"))
        hintSearch.sendsSearchStringImmediately = true
        hintSearch.delegate = self
        for view in [hintHeading!, hintMode, hintSearch, hintRows] { add(view, to: hints) }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updatePolling), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePolling()
    }

    func configure(model: SessionInfoModel, session: TerminalSession?, remoteProject: Project?,
                   editor: ExternalEditor, showsVimHints: Bool, fontScale: CGFloat) {
        let changedSession = self.session?.id != session?.id
        let changedStyle = self.fontScale != fontScale || accentColor != Theme.accent
        self.session = session
        self.fontScale = fontScale
        accentColor = Theme.accent
        self.showsVimHints = showsVimHints
        if changedSession {
            hintSearch.stringValue = ""
            foregroundPid = nil
            setMode(nil)
            scroll.contentView.scroll(to: .zero)
        }
        // Process samples change every two seconds. Mode polling updates only
        // the hint rows, preserving the directory and process controls.
        let signature = "\(model.rootPath)|\(model.projectRootPath)|\(model.projectRootSource)|\(model.shellPid)|\(model.shellName)|\(model.processes)|\(model.ports)|\(fontScale)|\(editor)|\(remoteProject?.id.uuidString ?? "")|\(String(describing: remoteProject?.remoteConnectionState))|\(effectiveAppearance.name)"
        renderInformation = { [weak self, weak model, weak remoteProject] in
            guard let self, let model else { return }
            self.rebuildInformation(model: model, remoteProject: remoteProject, editor: editor)
        }
        if signature != informationSignature {
            informationSignature = signature
            renderInformation?()
        }
        if changedStyle { rebuildHints() }
        if !showsVimHints { setMode(nil) }
        updatePolling()
    }

    @objc private func refreshLanguage() {
        hintHeading.title = String(localized: "VIM COMMANDS")
        hintHeading.toolTip = hintHeading.title
        hintHeading.setAccessibilityLabel(hintHeading.title)
        hintSearch.placeholderString = String(localized: "Search Vim commands")
        hintSearch.setAccessibilityLabel(hintSearch.placeholderString)
        renderInformation?()
        rebuildHints()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func updatePolling() {
        guard showsVimHints, window?.isKeyWindow == true, NSApp.isActive,
              !isHiddenOrHasHiddenAncestor else {
            stopPolling()
            return
        }
        pollMode()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMode() }
        }
        timer?.tolerance = 0.1
    }

    private func pollMode() {
        guard let session, !session.hasExited, session.terminalIsAtLiveBottom,
              let foreground = session.surface.foregroundPid else {
            setMode(nil)
            return
        }
        let launchPID = session.shellPid
        let pid = VimModeDetection.inspectionPID(
            foregroundPID: foreground, launchPID: launchPID,
            launchProcessGroup: launchPID.map { getpgid($0) }
        )
        guard let path = processExecutablePath(pid: pid) else {
            setMode(nil)
            return
        }
        if foregroundPid != pid {
            foregroundPid = pid
            setMode(nil)
        }
        let executable = (path as NSString).lastPathComponent.lowercased()
        // Remote Vim without a filename opens a welcome screen whose identity
        // is in the center. Once recognized, only its status rows are needed.
        let sampleLines = mode == nil && VimModeDetection.transports.contains(executable) ? 120 : 8
        guard VimModeDetection.canInspect(executable: executable),
              let text = session.surface.readVisibleText(maxLines: sampleLines, maxColumns: 512) else {
            setMode(nil)
            return
        }
        setMode(VimModeDetection.detect(executable: executable, title: session.title,
                                       text: text, previouslyDetected: mode != nil))
    }

    private func setMode(_ next: VimMode?) {
        guard next != mode else { return }
        mode = next
        rebuildHints()
    }

    private func rebuildHints() {
        clear(hintRows)
        hints.isHidden = mode == nil
        guard let mode else { return }
        let isCollapsed = collapsed.contains("vim")
        hintHeading.font = .systemFont(ofSize: 9.5 * fontScale, weight: .medium)
        hintHeading.contentTintColor = .secondaryLabelColor
        hintHeading.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        hintHeading.setAccessibilityValue(String(localized: isCollapsed ? "Collapsed" : "Expanded"))
        hintMode.stringValue = String(localized: "\(mode.title) commands first")
        hintMode.font = .systemFont(ofSize: 11 * fontScale, weight: .semibold)
        hintMode.textColor = Theme.accent
        hintMode.lineBreakMode = .byTruncatingTail
        hintSearch.font = .systemFont(ofSize: 11 * fontScale)
        for view in [hintMode, hintSearch, hintRows] { view.isHidden = isCollapsed }
        guard !isCollapsed else { return }
        renderHintRows()
    }

    func controlTextDidChange(_ notification: Notification) {
        renderHintRows()
    }

    private func renderHintRows() {
        clear(hintRows)
        guard let mode else { return }
        let entries = VimCommandCatalog.ordered(for: mode, query: hintSearch.stringValue)
        if entries.isEmpty {
            add(label(String(localized: "No matching Vim commands"), size: 11, color: .secondaryLabelColor), to: hintRows)
        }
        for entry in entries {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            let keys = label(entry.command.keys, size: 11, weight: .medium)
            keys.font = .monospacedSystemFont(ofSize: 11 * fontScale, weight: .medium)
            add(keys, to: row)
            add(label(entry.command.explanation, size: 10, color: .secondaryLabelColor), to: row)
            add(label(entry.modeDescription, size: 9, color: .secondaryLabelColor), to: row)
            add(row, to: hintRows)
        }
    }

    private func rebuildInformation(model: SessionInfoModel, remoteProject: Project?, editor: ExternalEditor) {
        clear(information)
        if let remoteProject {
            let remote = RemoteProjectInfoNSView()
            remote.configure(project: remoteProject)
            add(remote, to: information)
            return
        }
        let header = NSStackView()
        header.orientation = .horizontal
        let title = label(model.shellName.isEmpty ? String(localized: "Session") : model.shellName,
                          size: 12, weight: .semibold)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        let refresh = button("", symbol: "arrow.clockwise", help: String(localized: "Refresh")) { [weak model] in
            model?.refresh()
        }
        header.addArrangedSubview(refresh)
        add(header, to: information)
        if model.shellPid > 0 { add(label("pid \(model.shellPid)", size: 10, color: .secondaryLabelColor), to: information) }
        if model.rootPath != model.projectRootPath {
            section("cwd", title: String(localized: "CURRENT DIRECTORY"), in: information) {
                directory(model.rootPath, editor: editor)
            }
        }
        if !model.projectRootPath.isEmpty {
            let title: String = switch model.projectRootSource {
            case .pinned: String(localized: "PROJECT DIRECTORY")
            case .shell: String(localized: "PROJECT DIRECTORY (AUTO)")
            case .foreground(let isWorktree): isWorktree
                ? String(localized: "PROJECT DIRECTORY (WORKTREE)")
                : String(localized: "PROJECT DIRECTORY (JOB)")
            }
            section("root", title: title, in: information,
                    help: String(localized: "Files and Git anchor to this directory. When automatic, it follows the closest Git repository containing the shell’s current directory, or the one the terminal’s foreground job moved to — a coding agent that switched to its own worktree. A directory set manually from the project’s context menu is always used as-is.")) {
                directory(model.projectRootPath, editor: editor)
            }
        }
        section("processes", title: String(localized: "PROCESSES"), count: model.processes.count, in: information) {
            if model.processes.isEmpty {
                add(label(String(localized: "No running processes"), size: 11, color: .secondaryLabelColor), to: information)
            }
            for process in model.processes {
                let row = InfoActionRow()
                row.setAccessibilityLabel("\(process.name), pid \(process.pid)")
                row.addArrangedSubview(label("●", size: 8, color: .systemGreen))
                let name = label("\(process.name)  \(process.pid)", size: 11)
                name.maximumNumberOfLines = 1
                name.lineBreakMode = .byTruncatingTail
                name.toolTip = process.executable
                row.addArrangedSubview(name)
                row.addArrangedSubview(NSView())
                let usage = label("\(Int(process.cpu))% · \(process.memoryLabel)", size: 10, color: .secondaryLabelColor)
                usage.maximumNumberOfLines = 1
                row.addArrangedSubview(usage)
                row.menu = menu([
                    (String(localized: "Terminate"), { [weak model] in model?.kill(process.pid) }),
                    (String(localized: "Force Kill"), { [weak model] in model?.kill(process.pid, force: true) }),
                    (String(localized: "Copy PID"), { Self.copy(String(process.pid)) }),
                    (String(localized: "Copy Executable Path"), { Self.copy(process.executable) }),
                ])
                row.actionButton = button("", symbol: "xmark", help: String(localized: "Terminate Process")) { [weak model] in
                    model?.kill(process.pid)
                }
                add(row, to: information)
            }
        }
        section("ports", title: String(localized: "PORTS"), count: model.ports.count, in: information) {
            if model.ports.isEmpty {
                add(label(String(localized: "No listening ports"), size: 11, color: .secondaryLabelColor), to: information)
            }
            for port in model.ports {
                let urlString = "http://localhost:\(port.port)"
                let open = { if let url = port.url { NSWorkspace.shared.open(url) } }
                let row = button("\(port.port)  \(port.processName)", symbol: "network",
                                 help: String(localized: "Open \(urlString)"), action: open)
                row.menu = menu([
                    (String(localized: "Open in Browser"), open),
                    (String(localized: "Copy URL"), { Self.copy(urlString) }),
                    (String(localized: "Kill Process (\(port.processName))"), { [weak model] in model?.kill(port.pid) }),
                ])
                add(row, to: information)
            }
        }
    }

    private func directory(_ path: String, editor: ExternalEditor) {
        let value = label(path, size: 11, color: .secondaryLabelColor)
        value.isSelectable = true
        value.maximumNumberOfLines = 2
        value.lineBreakMode = .byTruncatingHead
        value.toolTip = path
        value.menu = menu([(String(localized: "Copy Path"), { Self.copy(path) })])
        add(value, to: information)
        let actions = NSStackView()
        actions.distribution = .fillEqually
        actions.spacing = 4
        let url = URL(fileURLWithPath: path)
        actions.addArrangedSubview(button("Finder", symbol: "arrow.up.forward.app", help: String(localized: "Open in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        let openEditor = button(editor.title, symbol: "chevron.left.forwardslash.chevron.right",
                                help: String(localized: "Open in \(editor.title)")) { editor.open(url) }
        openEditor.isEnabled = editor.isAvailable
        actions.addArrangedSubview(openEditor)
        actions.addArrangedSubview(button(String(localized: "Copy"), symbol: "doc.on.doc", help: String(localized: "Copy Path")) {
            Self.copy(path)
        })
        add(actions, to: information)
    }

    private func section(_ id: String, title: String, count: Int = 0, in stack: NSStackView,
                         help: String? = nil, body: () -> Void) {
        let heading = button(count > 0 ? "\(title)  \(count)" : title,
                             symbol: collapsed.contains(id) ? "chevron.right" : "chevron.down",
                             help: help ?? title) { [weak self] in
            guard let self else { return }
            if self.collapsed.contains(id) { self.collapsed.remove(id) }
            else { self.collapsed.insert(id) }
            if id == "vim" { self.rebuildHints() }
            else { self.renderInformation?() }
        }
        heading.font = .systemFont(ofSize: 9.5 * fontScale, weight: .medium)
        heading.contentTintColor = .secondaryLabelColor
        heading.setAccessibilityValue(String(localized: collapsed.contains(id) ? "Collapsed" : "Expanded"))
        add(heading, to: stack)
        if !collapsed.contains(id) { body() }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size * fontScale, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func button(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
        let button = SettingsActionButton(title: title, action: action)
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10 * fontScale, weight: .regular))
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.font = .systemFont(ofSize: 10 * fontScale)
        button.toolTip = help
        button.setAccessibilityLabel(title.isEmpty ? help : title)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func menu(_ actions: [(String, () -> Void)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in actions { menu.addItem(InfoMenuItem(title: title, handler: action)) }
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class InfoMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

private final class InfoActionRow: NSStackView {
    var actionButton: NSButton? {
        didSet {
            oldValue?.removeFromSuperview()
            if let actionButton {
                addArrangedSubview(actionButton)
                actionButton.alphaValue = 0
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { actionButton?.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { actionButton?.alphaValue = 0 }
}

private final class InfoDocumentStack: NSStackView {
    override var isFlipped: Bool { true }
}
