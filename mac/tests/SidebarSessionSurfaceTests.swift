import AppKit
import SwiftUI
import Darwin
import ObjectiveC.runtime
@testable import zshell

@MainActor private func pump(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}
@MainActor private func descendants<T: NSView>(_ root: NSView, as type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, as: type) }
}
extension NSApplication {
    @objc(sidebarProbe_activate) fileprivate func sidebarProbe_activate() {}
}
@main struct SidebarSessionSurfaceTests {
    @MainActor static func main() {
        if PTYMuxCommandLine.shouldRunChild { PTYMuxCommandLine.runChild() }
        if PTYMuxCommandLine.shouldRunRelay { PTYMuxRelay.run() }
        if PTYMuxCommandLine.shouldRunDaemon { PTYMuxCommandLine.runDaemon() }
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("Sidebar production probe failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        QuickTerminalOffscreen.install()
        guard let activate = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("activate")),
              let replacement = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("sidebarProbe_activate")) else {
            throw NSError(domain: "offscreen activation", code: 1)
        }
        method_exchangeImplementations(activate, replacement)
        defer { method_exchangeImplementations(activate, replacement) }
        let settings = AppSettings.shared
        let backend = CommandLine.arguments[1]
        settings.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        settings.language = .english
        settings.notifyOnAgentAttention = false
        settings.notifyOnAgentCompletion = false
        settings.terminalStartupProgram = ""
        settings.preserveTerminalSessions = false
        settings.restoreTerminalHistory = false
        settings.resumeAgentConversations = false
        settings.showSidebarSessions = true
        settings.compactSidebar = false
        let root = FileManager.default.homeDirectoryForCurrentUser
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = GitStatusModel.runGit(["init","-q","-b","sidebar-fixture"], in: repository.path, timeout: 3)
        let manager = TerminalManager()
        manager.projects.forEach { manager.close($0) }
        let project = manager.newProject()
        project.customName = "Sidebar fixture"
        project.customDirectory = repository.path
        project.sessions.forEach { project.closeContent(.session($0)) }
        guard let first = project.newSession(directory: repository.path, commandArguments: ["/bin/sh","-i"],
            usesConfiguredStartupCommand: false, usesConfiguredInitializationCommand: false), let tab = project.selectedTab else {
            throw NSError(domain:"session",code:1)
        }
        first.title = "FIRST"
        project.splitRight()
        guard let second = project.selectedSession else { throw NSError(domain:"split",code:1) }
        second.title = "SECOND"
        tab.customName = "Split session"
        project.isSidebarExpanded = true
        tab.isSidebarExpanded = true
        let other = manager.newProject()
        other.customName = "Other project"
        manager.selectedProjectID = other.id
        let window = NSWindow(contentRect: NSRect(x:-100000,y:-100000,width:1250,height:760),
            styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        manager.attach(to: window)
        QuickTerminalOffscreen.prepare(window)
        defer {
            manager.projects.forEach { $0.terminateAll() }
            manager.windowClosed()
            pump(0.5)
            window.contentView = nil
            window.close()
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: app)
        }
        var checks=0
        func check(_ condition: Bool,_ label:String) throws {
            guard condition else { throw NSError(domain:"sidebar",code:2,userInfo:[NSLocalizedDescriptionKey:label]) }
            checks+=1; print("PASS \(backend): \(label)")
        }
        func wait(_ label:String,_ condition:()->Bool) throws {
            let deadline=Date().addingTimeInterval(12)
            while Date()<deadline { if condition(){return};pump(0.03) }
            throw NSError(domain:"wait",code:3,userInfo:[NSLocalizedDescriptionKey:label])
        }
        func layout(){first.title="FIRST";second.title="SECOND";host.frame=NSRect(x:0,y:0,width:1250,height:760);host.layoutSubtreeIfNeeded();pump(0.15)}
        layout()
        try wait("production sidebar mounted") { !descendants(host,as:ProjectSidebarNSView.self).isEmpty }
        let sidebar=descendants(host,as:ProjectSidebarNSView.self)[0]
        sidebar.frame.size.width=200
        sidebar.layoutSubtreeIfNeeded()
        func rows()->[WorkspaceItemView]{descendants(sidebar,as:WorkspaceItemView.self)}
        func row(_ name:String)->WorkspaceItemView? {
            if name == "FIRST" || name == "SECOND" {
                first.title = "FIRST"; second.title = "SECOND"
                sidebar.refresh(); sidebar.layoutSubtreeIfNeeded()
            }
            return rows().first { $0.titleLabel.stringValue == name }
        }
        try wait("background pane names updated") { row("FIRST") != nil && row("SECOND") != nil }
        try check(backend == "ghostty" ? first.surface is ZshellTerminalView : first.surface is AlacrittyTerminalView,
            "fixture uses the requested real terminal backend")
        try check(row("Split session") != nil, "project expands into native tab and pane rows")
        try check(row("FIRST")!.frame.maxX<=200, "pane rows fit a 200-point sidebar")
        let firstID=ObjectIdentifier(first.surface), secondID=ObjectIdentifier(second.surface)
        let before=tab.layout
        row("FIRST")?.onSelect?();layout()
        try check(manager.selectedProjectID==project.id && project.selectedTabID==tab.id && tab.focusedContent?.id==first.id,
            "click selects the correct project, tab and first pane")
        try wait("first pane surface receives focus"){window.firstResponder===first.surface}
        try check(ObjectIdentifier(first.surface)==firstID && ObjectIdentifier(second.surface)==secondID,
            "switching preserves both real terminal surfaces")
        tab.isZoomed=true
        row("FIRST")?.onSelect?();layout()
        try check(tab.isZoomed && tab.focusedContent?.id==first.id,
            "selecting the focused pane preserves its zoom")
        row("Split session")?.onSelect?();layout()
        try check(tab.isZoomed, "selecting a split tab preserves its focused pane zoom")
        guard let zoomAction = row("FIRST")?.menuItems?().compactMap({ item -> (() -> Void)? in
            if case .action(let title, let enabled, let handler) = item,
               enabled, title == String(localized: "Toggle Pane Zoom") { return handler }
            return nil
        }).first else { throw NSError(domain: "pane zoom menu", code: 4) }
        zoomAction();layout()
        try check(!tab.isZoomed, "the pane context menu toggles an already zoomed pane off")
        zoomAction();layout()
        try check(tab.isZoomed, "the pane context menu toggles the focused pane zoom on")
        row("SECOND")?.onSelect?();layout()
        try check(tab.focusedContent?.id==second.id && !tab.isZoomed, "pane click reveals a sibling from a zoomed layout")
        try wait("second pane receives native focus"){window.firstResponder===second.surface}
        try check(before.allPanes.map(\.id)==tab.layout.allPanes.map(\.id), "focus keeps the split tree intact")
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
        }
        let firstNative = row("FIRST")!
        window.makeFirstResponder(firstNative)
        firstNative.keyDown(with: key(125))
        try check(window.firstResponder === row("SECOND"), "arrow keys traverse native pane rows")
        row("SECOND")?.keyDown(with: key(123))
        try check(window.firstResponder === row("Split session"), "Left returns from a pane to its tab")
        row("Split session")?.keyDown(with: key(124))
        try check(window.firstResponder === row("FIRST"), "Right enters an expanded split tab")
        row("FIRST")?.keyDown(with: key(36));layout()
        try check(tab.focusedContent?.id == first.id, "Return focuses the row's real pane")
        let selection=manager.selectedProjectID
        let expandedState = row("Split session")?.accessibilityValue() as? String ?? ""
        try check(expandedState.contains(String(localized: "Selected")) && expandedState.contains(String(localized: "Expanded")),
            "a selected split tab exposes selection and expansion together")
        row("Split session")?.onDisclosure?();layout()
        try check(!tab.isSidebarExpanded && row("FIRST")==nil, "tab disclosure folds pane rows")
        let collapsedState = row("Split session")?.accessibilityValue() as? String ?? ""
        try check(collapsedState.contains(String(localized: "Selected")) && collapsedState.contains(String(localized: "Collapsed")),
            "a selected folded split tab exposes selection and collapse together")
        try check(manager.selectedProjectID==selection,"disclosure does not select another project")
        row("Split session")?.onDisclosure?();layout()
        AgentAutomationMonitor.shared.unregister(second)
        second.agentStatus=ZshellAgentStatus(alias:"agent-two",kind:.codex,phase:.blocked,authority:.report,reason:"Input required",
            updatedAt:Date(),processID:nil,unseen:true,progress:nil,attention:nil,tasks:[])
        pump(0.15);sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
        try check((row("SECOND")?.accessibilityValue() as? String)?.contains(ZshellAgentPhase.blocked.statusDescription)==true, "pane status is available as accessible text")
        let secondRow=row("SECOND")!
        try check(descendants(secondRow,as:AgentStatusBadgeView.self).contains{!$0.isHidden}, "status glyph remains visible at 200 points")
        let regularHeight=secondRow.frame.height
        settings.compactSidebar=true;pump(0.1);sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
        try check(row("SECOND")!.frame.height<regularHeight, "compact setting reduces native row height")
        settings.compactSidebar=false;pump(0.1);sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
        try wait("branch metadata updated for background pane") { row("SECOND")?.toolTip?.contains("sidebar-fixture")==true }
        let scroll=descendants(sidebar,as:NSScrollView.self)[0]
        let document=scroll.documentView!
        func mouse(_ point:NSPoint,_ count:Int)->NSEvent{
            let location=document.convert(point,to:nil)
            return NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:count,pressure:1)!
        }
        let count=project.tabs.count
        let blank=NSPoint(x:20,y:document.bounds.height-10)
        document.mouseDown(with:mouse(blank,2));layout()
        try check(project.tabs.count==count+1,"blank double click creates exactly one session in selected project")
        settings.sidebarDoubleClickNewSession=false
        document.mouseDown(with:mouse(blank,2));layout()
        try check(project.tabs.count==count+1,"disabled blank double click creates no session")
        settings.sidebarDoubleClickNewSession=true
        let firstFrame=row("FIRST")!.frame
        document.mouseDown(with:mouse(NSPoint(x:firstFrame.midX,y:firstFrame.midY),2));layout()
        try check(project.tabs.count==count+1,"row area does not trigger the blank double click gesture")
        let snapshot=SessionSnapshot.ProjectSnapshot(customName:project.customName,isSidebarExpanded:true,customDirectory:nil,
            tabs:[.init(layout:.pane(.init(content:.session(workingDirectory:repository.path),weight:1)),focusedPaneIndex:0,isSidebarExpanded:true)],selectedTabIndex:0)
        let roundtrip=try JSONDecoder().decode(SessionSnapshot.ProjectSnapshot.self,from:JSONEncoder().encode(snapshot))
        try check(roundtrip.isSidebarExpanded && roundtrip.tabs[0].isSidebarExpanded,"project and tab expansion survive snapshot round trip")
        let legacy = try JSONDecoder().decode(SessionSnapshot.ProjectSnapshot.self,
            from: Data(#"{"customName":null,"customDirectory":null,"tabs":[],"selectedTabIndex":null}"#.utf8))
        try check(!legacy.isSidebarExpanded, "legacy workspace snapshots default to folded projects")
        second.agentStatus=ZshellAgentStatus(alias:"agent-two",kind:.codex,phase:.blocked,authority:.report,reason:"Input required",
            updatedAt:Date(),processID:nil,unseen:true,progress:nil,attention:nil,tasks:[])
        let languages = AppLanguage.allCases.filter { $0 != .system }
        for language in languages {
            settings.language = language
            settings.interfaceScale = AppSettings.interfaceScaleRange.upperBound
            settings.sidebarFontSize = AppSettings.sidebarFontSizeRange.upperBound
            sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
            row("SECOND")?.scrollToVisible(row("SECOND")!.bounds)
            for nativeRow in rows() where nativeRow.frame.intersects(document.visibleRect) {
                nativeRow.layoutSubtreeIfNeeded()
                let title = nativeRow.titleLabel.frame
                for badge in descendants(nativeRow, as: AgentStatusBadgeView.self) where !badge.isHidden {
                    try check(!title.intersects(badge.frame), "\(language.rawValue) max-size title keeps the status badge separate")
                }
                try check(title.width > 0 && title.minX >= 0 && title.maxX <= nativeRow.bounds.maxX + 1,
                    "\(language.rawValue) max-size row truncates within its 200-point bounds")
            }
        }
        settings.language = .english
        settings.interfaceScale = AppSettings.defaultInterfaceScale
        settings.sidebarFontSize = AppSettings.defaultSidebarFontSize
        sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
        let retainedAction = row("FIRST")!.onSelect!
        let movedTabID = tab.id
        let receiver = TerminalManager()
        let receiverProject = receiver.selectedProject!
        receiverProject.customName = "Destination project"
        receiverProject.isSidebarExpanded = true
        let receiverWindow = NSWindow(contentRect: NSRect(x: -100000, y: -100000, width: 1250, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        receiverWindow.isReleasedWhenClosed = false
        let receiverHost = NSHostingView(rootView: ContentView(manager: receiver))
        receiverWindow.contentView = receiverHost
        receiver.attach(to: receiverWindow)
        QuickTerminalOffscreen.prepare(receiverWindow)
        defer {
            receiver.projects.forEach { $0.terminateAll() }
            receiver.windowClosed()
            pump(0.3)
            receiverWindow.contentView = nil
            receiverWindow.close()
        }
        let move = manager.moveTab(id: movedTabID, from: project.id, to: receiverProject.id, in: ObjectIdentifier(receiver))
        try check(move.failure == nil && receiverProject.tabs.contains(where: { $0 === tab }),
            "moving a split tab to another window keeps its live model")
        receiverHost.frame = NSRect(x: 0, y: 0, width: 1250, height: 760)
        receiverHost.layoutSubtreeIfNeeded();pump(0.2)
        manager.selectedProjectID = other.id
        retainedAction()
        receiverHost.layoutSubtreeIfNeeded();pump(0.2)
        try check(receiver.selectedProjectID == receiverProject.id && receiverProject.selectedTabID == movedTabID
            && tab.focusedContent?.id == first.id, "a retained sidebar action resolves the moved pane in its new window")
        try wait("moved pane receives destination-window focus") { receiverWindow.firstResponder === first.surface }
        try check(ObjectIdentifier(first.surface) == firstID && ObjectIdentifier(second.surface) == secondID
            && tab.isSidebarExpanded, "cross-window transfer preserves terminal surfaces and expansion")
        let fileURL = root.appendingPathComponent("sidebar-file.txt")
        try "fixture".write(to: fileURL, atomically: true, encoding: .utf8)
        let file = FileTab(path: fileURL.path)
        let fileTab = other.register(PaneTab(content: .file(file)))
        fileTab.customName = "File row"
        other.tabs.append(fileTab)
        other.isSidebarExpanded = true
        manager.selectedProjectID = other.id
        other.selectedTabID = fileTab.id
        try wait("non-terminal row is visible") {
            sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
            return row("File row") != nil
        }
        try check(row("File row") != nil, "non-terminal content appears as a native session row")
        let fileRow = row("File row")!
        fileRow.onRename?()
        try wait("native row enters rename after the menu turn") { fileRow.isRenaming }
        guard let editor = descendants(fileRow, as: NSTextField.self).first(where: { $0.isEditable && !$0.isHidden }) else {
            throw NSError(domain: "rename field", code: 4)
        }
        editor.stringValue = "Renamed file tab"
        fileRow.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: editor))
        sidebar.refresh();sidebar.layoutSubtreeIfNeeded()
        try check(fileTab.customName == "Renamed file tab", "native sidebar rename updates the existing tab model")
        row("Renamed file tab")?.onSelect?();layout()
        try check(other.focusedContent?.id == file.id, "a non-terminal row focuses the correct file content")
        for index in 0..<500 {
            let placeholder = FileTab(path: fileURL.path)
            let placeholderTab = other.register(PaneTab(content: .file(placeholder)))
            placeholderTab.customName = "Virtual row \(index)"
            other.tabs.append(placeholderTab)
        }
        sidebar.refresh();sidebar.layoutSubtreeIfNeeded();pump(0.1)
        let nativeCount = rows().count
        try check(nativeCount < 35, "500 hidden tabs retain fewer than 35 native row views")
        let end = max(0, document.bounds.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(0.1)
        try check(row("Virtual row 499") != nil && rows().count < 35,
            "scrolling reuses bounded views and renders the final hidden tab")
        let target = other.tabs.first { $0.customName == "Virtual row 499" }!
        row("Virtual row 499")?.onSelect?();layout()
        try check(other.selectedTabID == target.id && other.focusedContent?.id == target.focusedContent?.id,
            "reused file rows select their current content identity")
        try check(!manager.revealPane(contentID: UUID()), "closed or unknown pane identities produce no selection")
        try check(QuickTerminalOffscreen.isSafe(),"production probe stayed offscreen and did not activate")
        print("SIDEBAR \(backend) \(checks) passed")
    }
}
