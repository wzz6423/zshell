//
//  SidebarView.swift
//  zshell
//

import AppKit
import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    let bottomBarHeight: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var groupStore = ProjectGroupStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("leftSidebarWidth") private var width: Double = 220
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]
    @State private var pendingRenamingGroupID: UUID?

    /// Projects without a group, in sidebar order (pinned first).
    private var ungroupedProjects: [(index: Int, project: Project)] {
        manager.projects.enumerated().compactMap { entry in
            entry.element.groupID == nil
                ? (index: entry.offset, project: entry.element)
                : nil
        }
    }

    private func projects(in group: ProjectGroup) -> [Project] {
        manager.projects.filter { $0.groupID == group.id }
    }

    private var sidebarWidthRange: ClosedRange<Double> {
        (160 * settings.interfaceScale)...(400 * settings.interfaceScale)
    }

    private var defaultSidebarWidth: Double {
        220 * settings.interfaceScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip housing the traffic-light buttons and the
            // control for collapsing this sidebar.
            HStack(spacing: 0) {
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                if manager.isFPSCounterVisible {
                    FPSBadge()
                        .padding(.trailing, 8)
                }
                ChromeIconButton(
                    systemImage: "sidebar.left",
                    tooltip: "Toggle Left Sidebar (⌘B)"
                ) {
                    manager.toggleLeftSidebar()
                }
            }
            .padding(.trailing, 8)
            .frame(height: 38)

            ScrollView {
                VStack(spacing: 3) {
                    // Ungrouped projects keep the pre-grouping layout: pinned
                    // rows first, in their existing order, at full indent.
                    ForEach(ungroupedProjects, id: \.project.id) { entry in
                        let project = entry.project
                        SidebarProjectRow(
                            project: project,
                            index: entry.index,
                            isSelected: project.id == manager.selectedProjectID,
                            select: { manager.selectedProjectID = project.id },
                            setPinned: { manager.setPinned($0, for: project) },
                            close: { manager.close(project) },
                            moveToGroup: { manager.moveProject(project, to: $0) },
                            isDragging: draggedProjectID == project.id,
                            onDrag: { updateProjectDrag(source: project.id, location: $0) },
                            onDragEnded: endProjectDrag,
                            fontSize: settings.sidebarFontSize * settings.interfaceScale
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProjectFramePreferenceKey.self,
                                    value: [project.id: proxy.frame(in: .global)]
                                )
                            }
                        }
                    }

                    // Groups follow, in saved order; each renders a header
                    // row (click to collapse) over its indented projects.
                    ForEach(groupStore.groups) { group in
                        SidebarGroupHeader(
                            group: group,
                            projectCount: projects(in: group).count,
                            isRenaming: pendingRenamingGroupID == group.id,
                            toggleCollapsed: {
                                var updated = group
                                updated.isCollapsed.toggle()
                                groupStore.update(updated)
                            },
                            beginRename: { pendingRenamingGroupID = group.id },
                            endRename: { pendingRenamingGroupID = nil },
                            applyRename: { newValue in
                                var updated = group
                                updated.name = newValue
                                groupStore.update(updated)
                            },
                            newProjectInGroup: { manager.newProject(in: group) },
                            changeFolder: {
                                pickGroupFolder(group: group, store: groupStore)
                            },
                            removeGroup: {
                                for project in projects(in: group) {
                                    manager.moveProject(project, to: nil)
                                }
                                groupStore.remove(group)
                            }
                        )

                        if !group.isCollapsed {
                            ForEach(projects(in: group)) { project in
                                SidebarProjectRow(
                                    project: project,
                                    index: nil,
                                    isSelected: project.id == manager.selectedProjectID,
                                    select: { manager.selectedProjectID = project.id },
                                    setPinned: { manager.setPinned($0, for: project) },
                                    close: { manager.close(project) },
                                    moveToGroup: { manager.moveProject(project, to: $0) },
                                    isDragging: draggedProjectID == project.id,
                                    onDrag: { updateProjectDrag(source: project.id, location: $0) },
                                    onDragEnded: endProjectDrag,
                                    fontSize: settings.sidebarFontSize * settings.interfaceScale
                                )
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ProjectFramePreferenceKey.self,
                                            value: [project.id: proxy.frame(in: .global)]
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .background {
                SidebarFolderDropView(manager: manager)
            }

            HStack(spacing: 2) {
                SidebarFooterButton(
                    systemImage: "plus",
                    tooltip: "New Project (⌘N)"
                ) { manager.newProject() }
                SidebarFooterButton(
                    systemImage: "folder.badge.plus",
                    tooltip: "New Group"
                ) {
                    showNewGroupMenu()
                }
                SidebarFooterButton(
                    systemImage: "network",
                    tooltip: "New SSH Project"
                ) { manager.promptForSSHProject() }
                SidebarFooterButton(
                    systemImage: "bolt",
                    tooltip: "Quick Launch (⌘O)"
                ) { manager.toggleQuickLaunch() }
                Spacer()
                SidebarFooterButton(
                    systemImage: "exclamationmark.bubble",
                    tooltip: "Send Feedback",
                    tooltipAlignment: .trailing
                ) {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/wzz6423/zshell/issues/new")!
                    )
                }
                SidebarFooterButton(
                    systemImage: "gearshape",
                    tooltip: "Settings (⌘,)",
                    tooltipAlignment: .trailing
                ) { SettingsWindowController.shared.show() }
            }
            .padding(.horizontal, 8)
            .frame(height: bottomBarHeight)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(height: 1)
            }
        }
        .frame(width: width)
        .background {
            // Zshell's built-in Default themes keep the native translucent
            // sidebar material; every other theme — including the GitHub
            // originals they're based on — paints its flat sidebar shade so
            // the strip follows the palette.
            if Theme.isDefault(dark: colorScheme == .dark) {
                VisualEffectView(material: .sidebar)
            } else {
                Color(nsColor: Theme.sidebar)
            }
        }
        // Hairline between sidebar and content: themes fill both with the
        // same background, so the boundary needs its own line. The built-in
        // Defaults keep their material fill, whose contrast already draws
        // the edge.
        .overlay(alignment: .trailing) {
            if !Theme.isDefault(dark: colorScheme == .dark) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(
                edge: .trailing,
                width: $width,
                range: sidebarWidthRange,
                defaultWidth: defaultSidebarWidth,
                fontSize: settings.sidebarFontSize
            )
        }
        .onPreferenceChange(ProjectFramePreferenceKey.self) { projectFrames = $0 }
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
        draggedProjectID = source
        NSCursor.closedHand.set()
        guard let target = projectFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            manager.moveProject(source, to: target)
        }
    }

    private func endProjectDrag() {
        draggedProjectID = nil
        NSCursor.arrow.set()
    }

    /// The "+" group button: plain groups start empty, folder groups anchor a
    /// folder picked here so the group's name and directory both follow it.
    private func showNewGroupMenu() {
        let menu = NSMenu()
        let plain = NSMenuItem(
            title: String(localized: "Plain Group", comment: "Menu item creating a sidebar project group without a folder."),
            action: #selector(SidebarGroupMenuTarget.newPlainGroup(_:)),
            keyEquivalent: ""
        )
        plain.target = menuTarget
        menu.addItem(plain)
        let folder = NSMenuItem(
            title: String(localized: "Folder Group…", comment: "Menu item creating a sidebar project group anchored to a folder."),
            action: #selector(SidebarGroupMenuTarget.newFolderGroup(_:)),
            keyEquivalent: ""
        )
        folder.target = menuTarget
        menu.addItem(folder)

        menuTarget.kind = .none
        menuTarget.completion = { kind in
            if case .folder = kind {
                pickFolder { path in
                    guard let path else { return }
                    let group = ProjectGroup(
                        name: ProjectGroup.defaultName(for: .folder(path: path)),
                        kind: .folder(path: path)
                    )
                    groupStore.add(group)
                }
            } else {
                let group = ProjectGroup(name: ProjectGroup.defaultName(for: .plain), kind: .plain)
                groupStore.add(group)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Lets the user re-anchor a folder group.
    private func pickGroupFolder(group: ProjectGroup, store: ProjectGroupStore) {
        pickFolder(initial: group.folderPath) { path in
            guard let path else { return }
            var updated = group
            updated.kind = .folder(path: path)
            updated.name = ProjectGroup.defaultName(for: .folder(path: path))
            store.update(updated)
        }
    }

    private func pickFolder(
        initial: String? = nil,
        completion: @escaping (String?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button in the project directory picker.")
        if let initial {
            panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    /// Target for the NSMenu shown from the new-group button; SwiftUI menus
    /// can't be popped up imperatively, so this tiny object carries the two
    /// actions and hands the chosen kind back through `completion`.
    @State private var menuTarget = SidebarGroupMenuTarget()
}

@MainActor
private final class SidebarGroupMenuTarget: NSObject {
    enum PendingKind {
        case none
        case plain
        case folder
    }

    var kind: PendingKind = .none
    var completion: ((PendingKind) -> Void)?

    @objc func newPlainGroup(_ sender: NSMenuItem) {
        completion?(.plain)
        completion = nil
    }

    @objc func newFolderGroup(_ sender: NSMenuItem) {
        completion?(.folder)
        completion = nil
    }
}

private struct SidebarFolderDropView: NSViewRepresentable {
    let manager: TerminalManager

    func makeNSView(context: Context) -> SidebarFolderDropDestinationView {
        let view = SidebarFolderDropDestinationView()
        view.manager = manager
        return view
    }

    func updateNSView(_ view: SidebarFolderDropDestinationView, context: Context) {
        view.manager = manager
    }
}

@MainActor
private final class SidebarFolderDropDestinationView: NSView {
    weak var manager: TerminalManager?
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTarget else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 4),
            xRadius: 8,
            yRadius: 8
        )
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 2
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropState(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropState(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let directories = directories(from: sender), !directories.isEmpty,
              let manager else {
            NSSound.beep()
            announce(String(localized: "Only folders can be added as projects."))
            return false
        }

        let createdCount = manager.openOrFocusDirectories(directories)
        let message = createdCount == 0
            ? String(localized: "Project already open. Focused it in the sidebar.")
            : String(localized: "Added folder as a project.")
        announce(message)
        return true
    }

    private func updateDropState(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = directories(from: sender)?.isEmpty == false
        isDropTarget = acceptsDrop
        return acceptsDrop ? .copy : []
    }

    private func directories(from sender: NSDraggingInfo) -> [String]? {
        let pasteboard = sender.draggingPasteboard
        guard pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return nil }
        return ZshellApplicationDelegate.directories(from: pasteboard)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

struct ChromeIconButton: View {
    @ObservedObject private var settings = AppSettings.shared
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// `nil` follows the interface scale from Appearance settings; explicit
    /// values are sized by the call site.
    var font: Font? = nil
    var iconSize: CGFloat? = nil
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    private var scale: CGFloat { CGFloat(settings.interfaceScale) }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font ?? .system(size: 12 * scale, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize ?? 16 * scale, height: iconSize ?? 16 * scale)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
    }
}

/// Live frames-per-second readout in the header strip, fed by `FPSCounter`.
/// It exists only while the manager's toggle is on, so the counter starts
/// when the badge appears and stops when it leaves the hierarchy.
private struct FPSBadge: View {
    @StateObject private var counter = FPSCounter()

    var body: some View {
        Text("\(counter.fps) fps")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.07))
            )
            .onAppear { counter.start() }
            .onDisappear { counter.stop() }
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            systemImage: systemImage,
            tooltip: tooltip,
            tooltipEdge: .above,
            tooltipAlignment: tooltipAlignment,
            action: action
        )
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SidebarProjectRow: View {
    @ObservedObject var project: Project
    @ObservedObject private var themeChanges = Theme.changes
    /// Sidebar position for the ⌘N hint; nil for grouped rows, which do not
    /// claim a global shortcut slot.
    let index: Int?
    let isSelected: Bool
    let select: () -> Void
    let setPinned: (Bool) -> Void
    let close: () -> Void
    /// Reparents the project under another sidebar group; nil removes it
    /// from its group. Wired by the owner view.
    var moveToGroup: ((ProjectGroup?) -> Void)?
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                rowContent
            } else {
                Button(action: select) {
                    rowContent
                }
                .buttonStyle(.plain)
                // Double-click starts the inline rename, the same
                // affordance the tab strip and the context menu's
                // "Rename…" entry offer. Attached to the button itself
                // because a button consumes clicks before gestures on
                // enclosing views get a chance to recognize them.
                .onTapGesture(count: 2) { beginRename() }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDrag($0.location) }
                        .onEnded { _ in onDragEnded() }
                )
            }
        }
        .opacity(isDragging ? 0.65 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .overlay {
            if !isRenaming {
                MiddleClickCatcher(action: close)
            }
        }
        .onHover { isHovering = $0 }
        .background {
            AppKitContextMenuMonitor(items: projectContextMenuItems)
        }
    }

    private var projectContextMenuItems: [AppKitContextMenuItem] {
        var items: [AppKitContextMenuItem] = [
            .action(title: String(localized: project.isPinned ? "Unpin Project" : "Pin Project")) {
                setPinned(!project.isPinned)
            },
            .separator,
            .action(title: String(localized: "Rename…"), handler: beginRename),
        ]
        if project.customName != nil {
            items.append(.action(title: String(localized: "Use Automatic Title")) {
                project.customName = nil
            })
        }
        items.append(.separator)
        items.append(moveToGroupMenuItem)
        items.append(.separator)
        items.append(.action(title: String(localized: "Set Color Marker…")) {
            ProjectTabColorPanelController.shared.present(project: project)
        })
        if project.markerColor != nil {
            items.append(.action(title: String(localized: "Remove Color Marker")) {
                project.markerColor = nil
            })
        }
        items.append(.separator)
        items.append(.action(title: String(localized: "Set Project Directory…"), handler: pickProjectDirectory))
        if project.customDirectory != nil {
            items.append(.action(title: String(localized: "Use Automatic Directory")) {
                project.customDirectory = nil
            })
        }
        items.append(.separator)
        items.append(.action(title: String(localized: "Close Project"), handler: close))
        return items
    }

    /// "Move to Group" submenu: one entry per existing group, plus the
    /// remove-from-group action for grouped projects.
    private var moveToGroupMenuItem: AppKitContextMenuItem {
        let groups = ProjectGroupStore.shared.groups
        var entries: [AppKitContextMenuItem] = groups.map { group in
            .action(
                title: group.name,
                enabled: project.groupID != group.id
            ) { moveToGroup?(group) }
        }
        if !groups.isEmpty {
            entries.append(.separator)
        }
        entries.append(.action(
            title: String(localized: "Remove from Group", comment: "Menu item taking a project out of its sidebar group."),
            enabled: project.groupID != nil
        ) { moveToGroup?(nil) }
        )
        return .submenu(
            title: String(localized: "Move to Group", comment: "Menu item grouping a sidebar project."),
            enabled: !groups.isEmpty || project.groupID != nil,
            items: entries
        )
    }

    /// Lets the user pin the project's directory — the root the file tree
    /// and git panels anchor to instead of the automatic closest-git-repo.
    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button in the project directory picker.")
        panel.message = String(
            localized: "Choose the directory for “\(project.name)”.",
            comment: "Message in the project directory picker. The placeholder is a project name."
        )
        if let current = project.customDirectory
            ?? project.selectedSession?.currentDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            project.customDirectory = url.path
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.accent) : .secondary)
                .frame(width: max(14, fontSize), alignment: .center)

            if let markerColor = project.markerColor {
                Image(systemName: "tag.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(nsColor: markerColor.nsColor))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: projectTitleFontSize, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) {
                            if !renameFocused, isRenaming {
                                commitRename()
                            }
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: projectTitleFontSize))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
                subtitle
            }

            Spacer(minLength: 0)

            if let rollup = project.agentRollup, !isRenaming {
                AgentStatusBadgeRepresentable(rollup: rollup)
                    .fixedSize()
            }

            // Fixed trailing slot: close and the ⌘N hint share the same
            // width so hover does not reflow the row. Continuous title
            // updates from the terminal re-render the strip; without a
            // stable slot that reflow reads as jitter under the pointer.
            ZStack(alignment: .trailing) {
                if isHovering, !isRenaming {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if let index, index < 9, !isRenaming {
                    Text(verbatim: "⌘\(index + 1)")
                        .font(.system(size: supportingFontSize))
                        .foregroundStyle(.tertiary)
                }
            }
            // Grows with the sidebar font so the shortcut hint and close
            // button keep their slot instead of crowding the title.
            .frame(
                width: 24 * max(1, sidebarFontScale),
                height: 16 * max(1, sidebarFontScale),
                alignment: .trailing
            )
        }
        .padding(.leading, index == nil ? 18 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityValue(markerAccessibilityValue)
    }

    private var markerAccessibilityValue: String {
        guard let markerColor = project.markerColor else {
            return String(localized: "No color marker")
        }
        return String(
            localized: "Color marker \(markerColor.displayValue)",
            comment: "Accessibility value for a project or tab color marker. The placeholder is an sRGB hex color."
        )
    }

    private func beginRename() {
        renameDraft = project.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        project.customName = Project.normalizedCustomName(renameDraft)
        isRenaming = false
    }

    @ViewBuilder
    private var subtitle: some View {
        if project.sessions.count > 1 {
            Text("\(project.sessions.count) sessions")
                .font(.system(size: supportingFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let session = project.selectedSession {
            SessionDirectoryLabel(session: session, fontSize: supportingFontSize)
        }
    }

    private var supportingFontSize: Double {
        10 * sidebarFontScale
    }

    /// Match the file-tree label's designed 11.5 pt size while following the
    /// shared sidebar font-size setting.
    private var projectTitleFontSize: Double {
        11.5 * sidebarFontScale
    }

    private var sidebarFontScale: Double {
        fontSize / AppSettings.defaultSidebarFontSize
    }
}

/// Small subtitle showing a session's current directory; separate view so
/// it observes the session's own published working directory.
private struct SessionDirectoryLabel: View {
    @ObservedObject var session: TerminalSession
    let fontSize: Double

    var body: some View {
        if let dir = session.directoryLabel {
            Text(dir)
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
/// Sidebar section header for a project group: collapse toggle, the group's
/// icon (plain tray vs anchored folder), an inline rename field, and the
/// group context menu. The group's kind decides where sessions opened from
/// it start — home for a plain group, its folder for a folder group.
private struct SidebarGroupHeader: View {
    let group: ProjectGroup
    let projectCount: Int
    let isRenaming: Bool
    let toggleCollapsed: () -> Void
    let beginRename: () -> Void
    let endRename: () -> Void
    /// Commits a new group name (already trimmed by the caller's store).
    let applyRename: (String) -> Void
    let newProjectInGroup: () -> Void
    let changeFolder: () -> Void
    let removeGroup: () -> Void

    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                headerContent
            } else {
                Button(action: toggleCollapsed) {
                    headerContent
                }
                .buttonStyle(.plain)
                .onTapGesture(count: 2) { beginRename() }
            }
        }
        .background {
            AppKitContextMenuMonitor(items: groupContextMenuItems)
        }
    }

    private var groupContextMenuItems: [AppKitContextMenuItem] {
        var items: [AppKitContextMenuItem] = [
            .action(title: String(
                localized: "New Project in Group",
                comment: "Group menu item creating a project that opens in the group's directory."
            )) { newProjectInGroup() },
            .separator,
            .action(title: String(localized: "Rename…"), handler: beginRename),
        ]
        if group.folderPath != nil {
            items.append(.action(title: String(
                localized: "Change Folder…",
                comment: "Group menu item re-anchoring a folder group to another folder."
            )) { changeFolder() })
        }
        items.append(contentsOf: [
            .separator,
            .action(title: String(
                localized: "Remove Group",
                comment: "Group menu item deleting the group; its projects stay open, ungrouped."
            )) { removeGroup() },
        ])
        return items
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .accessibilityHidden(true)

            Image(systemName: group.folderPath == nil ? "tray.full" : "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: max(14, fontSize), alignment: .center)

            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .medium))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { endRename() }
                    .onChange(of: renameFocused) {
                        if !renameFocused, isRenaming { commitRename() }
                    }
            } else {
                Text(group.name)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(projectCount)")
                    .font(.system(size: fontSize - 1.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func commitRename() {
        renameDraft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !renameDraft.isEmpty { applyRename(renameDraft) }
        endRename()
    }

    private var fontSize: Double { 10.5 }
}
