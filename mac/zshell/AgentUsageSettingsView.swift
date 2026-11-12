//
//  AgentUsageSettingsView.swift
//  zshell
//

import AppKit

@MainActor
final class AgentUsageSettingsView: NSView {
    private let providerStack = NSStackView()
    private let claudeView = AgentUsageProviderView(kind: .claude)
    private let codexView = AgentUsageProviderView(kind: .codex)
    private let providerSeparator = SettingsSeparatorView()
    private let refreshButton = SettingsActionButton(
        title: String(localized: "Refresh Usage")
    ) {
        AgentUsageModel.shared.refresh()
    }
    private var providerWidthConstraints: [NSLayoutConstraint] = []

    private(set) var hasVisibleUsage = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 12

        providerStack.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(providerStack)
        addSubview(refreshButton)
        NSLayoutConstraint.activate([
            providerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            providerStack.topAnchor.constraint(equalTo: topAnchor),
            providerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            refreshButton.topAnchor.constraint(equalTo: providerStack.bottomAnchor, constant: 12),
            refreshButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            refreshButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(claude: AgentUsageProviderState, codex: AgentUsageProviderState) {
        let states = [claude, codex].filter { state in
            if case .disabled = state.availability { return false }
            return true
        }
        NSLayoutConstraint.deactivate(providerWidthConstraints)
        providerWidthConstraints.removeAll(keepingCapacity: true)
        providerStack.arrangedSubviews.forEach {
            providerStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, state) in states.enumerated() {
            if index > 0 {
                providerStack.addArrangedSubview(providerSeparator)
                providerWidthConstraints.append(
                    providerSeparator.widthAnchor.constraint(equalTo: providerStack.widthAnchor)
                )
            }
            let provider = state.kind == .claude ? claudeView : codexView
            provider.apply(state)
            providerStack.addArrangedSubview(provider)
            providerWidthConstraints.append(
                provider.widthAnchor.constraint(equalTo: providerStack.widthAnchor)
            )
        }
        NSLayoutConstraint.activate(providerWidthConstraints)
        hasVisibleUsage = !states.isEmpty
        refreshButton.isHidden = !hasVisibleUsage
        refreshButton.isEnabled = !states.contains(where: \.isRefreshing)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard hasVisibleUsage else { return .zero }
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(providerStack.fittingSize.height + 12 + refreshButton.fittingSize.height)
        )
    }
}

@MainActor
private final class AgentUsageProviderView: NSView {
    private let kind: ZshellAgentKind
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailStack = NSStackView()

    init(kind: ZshellAgentKind) {
        self.kind = kind
        super.init(frame: .zero)

        titleLabel.stringValue = kind.displayName
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 5

        let stack = NSStackView(views: [titleLabel, statusLabel, detailStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: AgentUsageProviderState) {
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch state.availability {
        case .disabled:
            statusLabel.stringValue = ""
        case .waiting:
            statusLabel.stringValue = String(localized: "Refreshing…")
        case .unavailable(let issue):
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…") : Self.issueLabel(issue)
        case .available(let snapshot):
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…") : Self.updatedLabel(snapshot.updatedAt)
            snapshot.windows.forEach(addWindow)
        case .stale(let snapshot, let issue):
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…") : String(localized: "Last available usage")
            let reason = NSTextField(wrappingLabelWithString: Self.issueLabel(issue))
            reason.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            reason.textColor = .secondaryLabelColor
            detailStack.addArrangedSubview(reason)
            reason.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            let updated = NSTextField(wrappingLabelWithString: Self.updatedLabel(snapshot.updatedAt))
            updated.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            updated.textColor = .tertiaryLabelColor
            detailStack.addArrangedSubview(updated)
            updated.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            snapshot.windows.forEach(addWindow)
        }
    }

    private func addWindow(_ window: AgentUsageWindow) {
        let label = NSTextField(wrappingLabelWithString: Self.windowTitle(window))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let percent = NSTextField(wrappingLabelWithString: String(
            localized: "\(Int(window.usedPercent.rounded()))% used",
            comment: "Account limit usage percentage"
        ))
        percent.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        percent.setContentHuggingPriority(.required, for: .horizontal)
        percent.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [label, percent])
        labels.orientation = .horizontal
        labels.alignment = .firstBaseline
        labels.spacing = 8
        detailStack.addArrangedSubview(labels)
        labels.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = min(max(window.usedPercent, 0), 100)
        progress.controlSize = .small
        detailStack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        if let reset = window.resetsAt {
            let resetLabel = NSTextField(wrappingLabelWithString: String(
                localized: "Resets \(reset.formatted(date: .abbreviated, time: .shortened))",
                comment: "Time when an account usage window resets"
            ))
            resetLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            resetLabel.textColor = .tertiaryLabelColor
            detailStack.addArrangedSubview(resetLabel)
            resetLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
    }

    private static func issueLabel(_ issue: AgentUsageIssue) -> String {
        switch issue {
        case .cliMissing: String(localized: "Codex CLI is not installed.")
        case .notSignedIn: String(localized: "Codex CLI is not signed in.")
        case .noClaudeSession: String(localized: "No Claude Code status-line usage report is available.")
        case .noLimits: String(localized: "No current account limits were reported.")
        case .timedOut: String(localized: "The usage request timed out. Try refreshing.")
        case .invalidResponse, .failed: String(localized: "Usage could not be read. Try refreshing.")
        }
    }

    private static func windowTitle(_ window: AgentUsageWindow) -> String {
        switch window.kind {
        case .fiveHour:
            return String(localized: "5-hour limit")
        case .sevenDay:
            return String(localized: "7-day limit")
        case .spend:
            return String(localized: "Spend limit")
        case .primary, .secondary:
            guard let minutes = window.durationMinutes, minutes > 0 else {
                return window.kind == .primary
                    ? String(localized: "Primary limit")
                    : String(localized: "Secondary limit")
            }
            if minutes % 10_080 == 0 {
                return String(
                    localized: "\(minutes / 10_080)-week limit",
                    comment: "Account limit window measured in weeks"
                )
            }
            if minutes % 1_440 == 0 {
                return String(
                    localized: "\(minutes / 1_440)-day limit",
                    comment: "Account limit window measured in days"
                )
            }
            if minutes % 60 == 0 {
                return String(
                    localized: "\(minutes / 60)-hour limit",
                    comment: "Account limit window measured in hours"
                )
            }
            return String(
                localized: "\(minutes)-minute limit",
                comment: "Account limit window measured in minutes"
            )
        }
    }

    private static func updatedLabel(_ date: Date) -> String {
        String(
            localized: "Updated \(date.formatted(date: .omitted, time: .shortened))",
            comment: "Last account usage refresh time"
        )
    }

}
