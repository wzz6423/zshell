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
    private let refreshButton = SettingsActionButton(
        title: String(localized: "Refresh Usage")
    ) {
        AgentUsageModel.shared.refresh()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 12
        providerStack.addArrangedSubview(claudeView)
        providerStack.addArrangedSubview(SettingsSeparatorView())
        providerStack.addArrangedSubview(codexView)
        for view in providerStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: providerStack.widthAnchor).isActive = true
        }

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
        claudeView.apply(claude)
        codexView.apply(codex)
        refreshButton.isEnabled = !claude.isRefreshing && !codex.isRefreshing
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(providerStack.fittingSize.height + 12 + refreshButton.fittingSize.height)
        )
    }
}

@MainActor
private final class AgentUsageProviderView: NSView {
    private let kind: ZshellAgentKind
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailStack = NSStackView()

    init(kind: ZshellAgentKind) {
        self.kind = kind
        super.init(frame: .zero)

        titleLabel.stringValue = kind.displayName
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        let header = NSStackView(views: [titleLabel, statusLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.distribution = .fill
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 5

        let stack = NSStackView(views: [header, detailStack])
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

        let availability = state.availability
        let snapshot: AgentUsageSnapshot?
        switch availability {
        case .waiting:
            snapshot = nil
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…")
                : String(localized: "Waiting for refresh")
        case .available(let value):
            snapshot = value
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…")
                : Self.updatedLabel(value.updatedAt)
        case .stale(let value, _):
            snapshot = value
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…")
                : String(localized: "Stale")
        case .unavailable(let issue):
            snapshot = nil
            statusLabel.stringValue = state.isRefreshing
                ? String(localized: "Refreshing…")
                : String(localized: "Unavailable")
            addDetail(Self.message(for: issue, provider: kind))
        }

        if let snapshot {
            for window in snapshot.windows {
                addWindow(window)
            }
            if case .stale(_, let issue) = availability {
                addDetail(Self.staleMessage(for: issue, provider: kind))
            }
        }
        addDetail(Self.sourceDescription(for: kind))
    }

    private func addWindow(_ window: AgentUsageWindow) {
        let label = NSTextField(labelWithString: Self.windowTitle(window))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = min(max(window.usedPercent, 0), 100)
        progress.controlSize = .small
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let percent = NSTextField(labelWithString: String(
            localized: "\(Int(window.usedPercent.rounded()))% used",
            comment: "Account limit usage percentage"
        ))
        percent.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        percent.alignment = .right
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, progress, percent])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        detailStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        if let reset = window.resetsAt {
            let resetLabel = NSTextField(labelWithString: String(
                localized: "Resets \(reset.formatted(date: .abbreviated, time: .shortened))",
                comment: "Time when an account usage window resets"
            ))
            resetLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            resetLabel.textColor = .tertiaryLabelColor
            detailStack.addArrangedSubview(resetLabel)
        }
    }

    private func addDetail(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        detailStack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
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

    private static func sourceDescription(for provider: ZshellAgentKind) -> String {
        switch provider {
        case .claude:
            return String(localized: "Source: Claude Code status line from an active Zshell session")
        case .codex:
            return String(localized: "Source: local Codex app server")
        default:
            return ""
        }
    }

    private static func message(
        for issue: AgentUsageIssue,
        provider: ZshellAgentKind
    ) -> String {
        switch (provider, issue) {
        case (.claude, .noClaudeSession), (.claude, .noLimits):
            return String(localized: "No rate-limit snapshot from an active Claude Code session yet.")
        case (.codex, .cliMissing):
            return String(localized: "Codex is not available on Zshell's app PATH.")
        case (.codex, .notSignedIn):
            return String(localized: "Codex is installed, but its local app server is not signed in.")
        case (_, .timedOut):
            return String(localized: "The local usage source did not respond in time.")
        case (_, .invalidResponse):
            return String(localized: "The local usage source returned an unsupported response.")
        default:
            return String(localized: "The local usage source could not be read.")
        }
    }

    private static func staleMessage(
        for issue: AgentUsageIssue,
        provider: ZshellAgentKind
    ) -> String {
        String(
            localized: "Showing the last local snapshot. \(message(for: issue, provider: provider))",
            comment: "Stale account usage explanation"
        )
    }
}
