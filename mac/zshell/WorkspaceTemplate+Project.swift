import Foundation

extension WorkspaceTemplate {
    @MainActor static func canCapture(_ project: Project) -> Bool {
        !project.tabs.isEmpty && (!project.isRemote || project.sharedHost != nil)
    }

    @MainActor static func capture(project: Project, name: String) throws -> WorkspaceTemplate {
        var remote: Remote?
        if project.isRemote {
            guard let host = project.sharedHost, let directory = project.remoteDirectory else {
                throw WorkspaceTemplateError.unsupportedRemoteProject
            }
            remote = Remote(host: host.name, directory: directory)
        }
        let directory = project.selectedSession?.currentDirectoryPath ?? NSHomeDirectory()
        let root = remote == nil ? project.panelRoot(followingSessionAt: directory).root : directory
        var simplified = 0
        let tabs = project.tabs.map { tab -> Tab in
            var terminals: [Terminal] = []
            var paneIndex = 0
            @MainActor func snapshot(_ node: PaneNode) -> Layout {
                switch node {
                case .pane(let pane):
                    let index = paneIndex
                    paneIndex += 1
                    let content: Content
                    switch pane.content {
                    case .session(let session):
                        content = .session(workingDirectory: remote == nil ? relativeDirectory(session.currentDirectoryPath, to: root) : ".")
                        let hasAgentIdentity = session.agentResume != nil
                        let argv = hasAgentIdentity ? nil : session.startupCommandForTemplate
                        terminals.append(Terminal(paneIndex: index, program: argv?.first,
                                                  arguments: argv.map { Array($0.dropFirst()) } ?? [],
                                                  initializationCommand: hasAgentIdentity ? nil : session.initializationCommandForTemplate))
                    case .browser(let browser):
                        content = .browser(url: capturedBrowserURL(browser.snapshotURL))
                    case .file, .diff:
                        simplified += 1
                        content = .session(workingDirectory: ".")
                        terminals.append(Terminal(paneIndex: index))
                    }
                    return .pane(SessionSnapshot.ProjectSnapshot.PaneSnapshot(content: content, weight: 1))
                case .split(let split):
                    return .split(axis: split.axis, fraction: Double(split.fraction),
                                  first: snapshot(split.first), second: snapshot(split.second))
                }
            }
            return Tab(name: tab.customName, layout: snapshot(tab.layout),
                       focusedPaneIndex: tab.allPanes.firstIndex { $0.id == tab.focusedPaneID } ?? 0,
                       terminals: terminals)
        }
        let template = WorkspaceTemplate(name: name, tabs: tabs,
                                         selectedTabIndex: project.tabs.firstIndex { $0.id == project.selectedTabID } ?? 0,
                                         simplifiedPaneCount: simplified, remote: remote)
        try template.validate()
        return template
    }
}
