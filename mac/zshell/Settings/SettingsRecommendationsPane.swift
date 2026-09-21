//
//  SettingsRecommendationsPane.swift
//  zshell
//

import AppKit
import Combine

final class SettingsRecommendationsPane: SettingsPaneViewController {
    private let service = RecommendedToolService()
    private let updater = Updater.shared
    private var rows: [RecommendedTool: SettingsRow] = [:]
    private var buttons: [RecommendedTool: SettingsActionButton] = [:]
    private var timer: Timer?
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var refreshButton = SettingsActionButton(title: String(localized: "Refresh")) { [weak self] in
        guard let self else { return }
        Task { await self.service.refresh(force: true) }
    }
    private lazy var installAllButton = SettingsActionButton(title: String(localized: "Install Missing")) { [weak self] in
        guard let self else { return }
        Task { await self.service.install(self.service.missingTools) }
    }
    private lazy var updateAllButton = SettingsActionButton(title: String(localized: "Update All")) { [weak self] in
        guard let self else { return }
        Task { await self.service.install(self.service.updatableTools) }
    }
    private lazy var homebrewButton = SettingsActionButton(title: String(localized: "Get Homebrew…")) {
        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
    }
    private lazy var homebrewRow = SettingsRow(
        title: "Homebrew", description: "", control: homebrewButton
    )

    override func makeGroups() -> [NSView] {
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [refreshButton, installAllButton, updateAllButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        let management = SettingsGroup(header: String(localized: "Manage Tools"), rows: [
            SettingsRow(
                title: String(localized: "\(RecommendedTool.allCases.count) recommended tools"),
                description: String(localized: "Versions are checked automatically while this page is open. Installations and updates start only when you click a button."),
                control: progress
            ),
            homebrewRow,
            SettingsCustomRow(actions),
            SettingsCustomRow(status),
        ])
        return [management] + RecommendedToolGroup.allCases.map { group in
            SettingsGroup(header: group.title, rows: RecommendedTool.allCases.filter { $0.group == group }.map(makeRow))
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(service.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() })
        observe(updater.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() })
        sync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await service.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.view.window?.isVisible == true else { return }
                await self.service.refresh()
            }
        }
    }

    override func viewWillDisappear() {
        timer?.invalidate()
        timer = nil
        super.viewWillDisappear()
    }

    private func makeRow(_ tool: RecommendedTool) -> NSView {
        let button = SettingsActionButton(title: String(localized: "Install")) { [weak self] in
            guard let self else { return }
            if tool == .zshell {
                self.updater.checkForUpdates()
            } else if self.service.states[tool]?.location == .homebrew && self.service.states[tool]?.hasUpdate != true {
                Task { await self.service.refresh(force: true) }
            } else {
                Task { await self.service.install([tool]) }
            }
        }
        button.setAccessibilityLabel(String(localized: "Manage \(tool.name)"))
        let row = SettingsRow(title: tool.name, description: tool.purpose, control: button)
        rows[tool] = row
        buttons[tool] = button
        return row
    }

    private func sync() {
        refreshButton.isEnabled = !service.isBusy
        installAllButton.isEnabled = !service.isBusy && service.homebrewURL != nil && !service.missingTools.isEmpty
        updateAllButton.isEnabled = !service.isBusy && service.homebrewURL != nil && !service.updatableTools.isEmpty
        installAllButton.toolTip = String(localized: "Download and install every missing recommended tool with Homebrew.")
        updateAllButton.toolTip = String(localized: "Update recommended tools managed by Homebrew that have a newer version.")
        homebrewButton.isHidden = service.homebrewURL != nil
        homebrewRow.setDescription(service.homebrewURL == nil
            ? String(localized: "Install Homebrew, then click Refresh to enable one-click installation.")
            : String(localized: "Tools are downloaded, installed, and updated through your Homebrew installation."))
        if service.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        if let tool = service.activeTool {
            status.stringValue = String(localized: "Installing or updating \(tool.name)…")
        } else if service.isRefreshing {
            status.stringValue = String(localized: "Checking installed tools and latest versions…")
        } else if let error = service.error {
            status.stringValue = error
        } else if service.states.values.contains(where: { $0.error != nil }) {
            status.stringValue = String(localized: "Some tools could not be checked. Click Refresh to retry.")
        } else {
            status.stringValue = String(localized: "\(service.updatableTools.count) updates available")
        }
        status.textColor = service.error == nil ? .secondaryLabelColor : .systemRed
        for tool in RecommendedTool.allCases {
            guard let row = rows[tool], let button = buttons[tool] else { continue }
            if tool == .zshell {
                row.setDescription(tool.purpose + "\n" + String(localized: "Zshell updates are managed in Updates settings."))
                button.title = updater.updateActionTitle
                button.isEnabled = updater.canCheckForUpdates && !updater.isUpdating
                continue
            }
            let state = service.states[tool] ?? RecommendedToolState()
            var detail = tool.purpose
            if let version = state.installedVersion {
                detail += "\n" + String(localized: "Installed: \(version)")
                if state.location == .external { detail += " · " + String(localized: "Outside Homebrew") }
            } else if state.isInstalled {
                detail += "\n" + String(localized: "Installed; version unavailable")
            } else {
                detail += "\n" + (state.hasCheckedInstallation
                    ? String(localized: "Not installed")
                    : String(localized: "Installation status not checked"))
            }
            if let version = state.latestVersion {
                detail += "\n" + String(localized: "Latest: \(version)")
            }
            if let error = state.error { detail += "\n" + error }
            if service.activeTool == tool { detail += "\n" + String(localized: "Installing or updating…") }
            row.setDescription(detail)
            button.title = state.location == .external ? String(localized: "Use Homebrew")
                : state.location == .homebrew ? (state.hasUpdate ? String(localized: "Update") : String(localized: "Recheck"))
                : String(localized: "Install")
            button.isEnabled = !service.isBusy && service.homebrewURL != nil
            button.toolTip = state.error ?? (state.location == .external
                ? String(localized: "Install a Homebrew-managed copy. Your existing installation may take precedence in PATH.")
                : String(localized: "Download and install with Homebrew."))
        }
    }
}
