import AppKit
import Combine

final class SettingsPermissionsPane: SettingsPaneViewController {
    private let coordinator: SettingsPermissionCoordinator
    private let dragHelper = SettingsPermissionDragHelper()
    private var rows: [SettingsPermission: SettingsRow] = [:]
    private var controls: [SettingsPermission: SettingsPermissionControl] = [:]

    convenience init() {
        self.init(coordinator: SettingsPermissionCoordinator())
    }

    init(coordinator: SettingsPermissionCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeGroups() -> [NSView] {
        [SettingsGroup(rows: SettingsPermission.allCases.map { permission in
            let control = SettingsPermissionControl(status: coordinator.statuses[permission] ?? .unavailable) { [weak self] in
                self?.coordinator.performAction(for: permission)
            }
            control.button.setAccessibilityIdentifier("permission-\(permission.rawValue)")
            let row = SettingsRow(
                title: permission.title, description: permission.explanation, control: control,
                symbolName: permission.symbolName, symbolColor: SettingsCategory.permissions.iconColor
            )
            rows[permission] = row
            controls[permission] = control
            return row
        })]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        coordinator.onOpenSettings = { [weak self] permission in
            guard let self else { return }
            if permission.supportsAppDrop { self.dragHelper.show() }
            else { self.dragHelper.hide() }
        }
        observe(coordinator.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() })
        observe(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            guard let self, self.view.window?.isVisible == true, self.view.superview != nil else { return }
            self.coordinator.refresh()
        })
        observe(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).sink { [weak self] notification in
            guard let self, notification.object as? NSWindow === self.view.window else { return }
            self.dragHelper.hide()
            self.coordinator.deactivate()
        })
        sync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        coordinator.activate()
    }

    override func viewWillDisappear() {
        dragHelper.hide()
        coordinator.deactivate()
        super.viewWillDisappear()
    }

    private func sync() {
        for permission in SettingsPermission.allCases {
            let status = coordinator.statuses[permission] ?? .unavailable
            controls[permission]?.update(status, enabled: coordinator.requesting == nil, permission: permission)
            let failure = coordinator.failures[permission].map { "\n" + $0.title } ?? ""
            rows[permission]?.setDescription(permission.explanation + failure)
        }
    }
}

private final class SettingsPermissionControl: NSView {
    let button: SettingsActionButton
    private let statusLabel = NSTextField(labelWithString: "")

    init(status: SettingsPermissionStatus, action: @escaping () -> Void) {
        button = SettingsActionButton(title: status.actionTitle, action: action)
        super.init(frame: .zero)
        statusLabel.stringValue = status.title
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [statusLabel, button])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 6
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

    func update(_ status: SettingsPermissionStatus, enabled: Bool, permission: SettingsPermission) {
        statusLabel.stringValue = status.title
        statusLabel.textColor = status == .granted ? .systemGreen : .secondaryLabelColor
        button.title = status.actionTitle
        button.isEnabled = enabled
        button.setAccessibilityLabel(status.actionTitle + " · " + permission.title)
    }
}
