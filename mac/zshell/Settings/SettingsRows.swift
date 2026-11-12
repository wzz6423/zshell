//
//  SettingsRows.swift
//  zshell
//

import AppKit

/// Multiline editors stay top-aligned so their first control remains beside
/// the title, while single controls center beside the row's text.
final class SettingsRow: NSView {
    private let descriptionLabel: NSTextField?
    private let stack = NSStackView()
    private var compoundWidths: [NSLayoutConstraint] = []
    private var compactWidth: CGFloat?

    init(title: String, description: String? = nil, control: NSView, symbolName: String? = nil, symbolColor: NSColor? = nil) {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = SettingsMetrics.rowTitleFont
        titleLabel.maximumNumberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel])
        if let description {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(label)
            descriptionLabel = label
        } else {
            descriptionLabel = nil
        }
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        for label in textStack.arrangedSubviews {
            label.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }

        super.init(frame: .zero)

        let descriptor = SettingsRowSymbols.icon(for: title, control: control)
        let labels = SettingsLabelColumn(
            title: titleLabel, text: textStack,
            symbolName: symbolName ?? descriptor.name,
            symbolColor: symbolColor ?? descriptor.category.iconColor
        )
        stack.addArrangedSubview(labels)
        stack.addArrangedSubview(control)
        stack.orientation = .horizontal
        stack.alignment = control is NSControl || description == nil ? .centerY : .top
        stack.spacing = SettingsMetrics.labelControlGap
        stack.distribution = .fill
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        if let actions = control as? NSStackView {
            actions.setHuggingPriority(.required, for: .horizontal)
            for view in actions.arrangedSubviews {
                view.setContentHuggingPriority(.required, for: .horizontal)
            }
        }
        if !(control is NSControl), description != nil,
           !(control is NSStackView) {
            compactWidth = control.fittingSize.width + SettingsMetrics.labelControlGap + SettingsMetrics.rowIconSize
                + SettingsMetrics.iconLabelGap + SettingsMetrics.rowTitleFont.pointSize * 12
            compoundWidths = [
                labels.widthAnchor.constraint(equalTo: stack.widthAnchor),
                control.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ]
        }
        if control.accessibilityLabel() == nil { control.setAccessibilityLabel(title) }

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

    /// Replaces the explanation under the title, for rows whose text depends on
    /// the value they show.
    func setDescription(_ text: String) {
        descriptionLabel?.stringValue = text
    }

    override func layout() {
        if let compactWidth, bounds.width > 0 {
            let compact = bounds.width < compactWidth
            if (stack.orientation == .vertical) != compact {
                NSLayoutConstraint.deactivate(compoundWidths)
                stack.orientation = compact ? .vertical : .horizontal
                stack.alignment = compact ? .leading : .top
                if compact { NSLayoutConstraint.activate(compoundWidths) }
            }
        }
        super.layout()
    }
}

/// Keep the icon beside the title's first line while explanations grow below it.
private final class SettingsLabelColumn: NSView {
    init(title: NSTextField, text: NSView, symbolName: String, symbolColor: NSColor) {
        super.init(frame: .zero)

        let icon = SettingsIconView(symbolName: symbolName, color: symbolColor, size: SettingsMetrics.rowIconSize)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: SettingsMetrics.rowIconBaselineOffset),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SettingsMetrics.iconLabelGap),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A row of views laid out left to right, the first one taking the slack. For
/// rows whose left side isn't a plain title — a notice, a badge and its
/// explanation.
final class SettingsStackRow: NSView {
    init(views: [NSView], alignment: NSLayoutConstraint.Attribute = .centerY) {
        super.init(frame: .zero)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = SettingsMetrics.labelControlGap
        stack.distribution = .fill
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in views.dropFirst() {
            view.setContentHuggingPriority(.required, for: .horizontal)
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
}

/// A row whose content already spans the card: a reused settings view that lays
/// out its own label and control, or a preview.
final class SettingsCustomRow: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A row holding a single button at the leading edge.
final class SettingsButtonRow: NSView {
    let button: NSButton

    init(title: String, action: @escaping () -> Void) {
        button = SettingsActionButton(title: title, action: action)
        super.init(frame: .zero)

        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Keep related actions together while allowing their full titles to wrap as a group.
final class SettingsButtonFlowRow: NSView {
    private let buttons: [NSButton]
    private let spacing: CGFloat = 8
    private var contentHeight: CGFloat = 0

    init(views: [NSButton]) {
        buttons = views
        super.init(frame: .zero)

        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.autoresizingMask = []
            if button.toolTip == nil { button.toolTip = button.title }
            if button.accessibilityLabel() == nil { button.setAccessibilityLabel(button.title) }
            addSubview(button)
        }
        contentHeight = buttons.filter { !$0.isHidden }.map { preferredSize(of: $0).height }.max() ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    override func layout() {
        super.layout()
        let availableWidth = max(0, bounds.width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for button in buttons where !button.isHidden {
            let preferred = preferredSize(of: button)
            let width = min(preferred.width, availableWidth)
            if x > 0, x + width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            button.frame = NSRect(x: x, y: y, width: width, height: preferred.height)
            x += width + spacing
            rowHeight = max(rowHeight, preferred.height)
        }
        let height = y + rowHeight
        if height != contentHeight {
            contentHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    private func preferredSize(of button: NSButton) -> NSSize {
        let fitting = button.fittingSize
        let intrinsic = button.intrinsicContentSize
        let alignmentSize = NSSize(
            width: max(0, intrinsic.width),
            height: max(0, intrinsic.height)
        )
        // The native bezel extends beyond the button's alignment rect.
        let frameSize = button.frame(forAlignmentRect: NSRect(origin: .zero, size: alignmentSize)).size
        return NSSize(width: max(0, ceil(max(fitting.width, frameSize.width))),
                      height: max(0, ceil(max(fitting.height, frameSize.height))))
    }
}

/// An `NSButton` that owns its own closure, so panes don't each need a
/// selector per button.
final class SettingsActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

/// Label, slider, numeric readout, and — where the old form had one — a
/// stepper. Used by every numeric setting so they all step and read alike.
final class SettingsSliderRow: NSView {
    /// How the readout beside the slider is written.
    enum Format {
        /// Whole points, "13 pt". The slider snaps to integers.
        case points
        /// A 0…1 fraction as a percentage, "75%".
        case percent
        /// An arbitrary numeric range displayed as a whole number.
        case integer
        /// A contrast ratio such as "3:1".
        case ratio
    }

    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let stepper: NSStepper?
    private let format: Format
    private let onChange: (Double) -> Void

    init(
        title: String,
        range: ClosedRange<Double>,
        format: Format,
        step: Double,
        showsStepper: Bool,
        accessibilityLabel: String? = nil,
        symbolName: String? = nil,
        symbolColor: NSColor? = nil,
        description: String? = nil,
        onChange: @escaping (Double) -> Void
    ) {
        self.format = format
        self.onChange = onChange
        stepper = showsStepper ? NSStepper() : nil
        super.init(frame: .zero)

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = SettingsMetrics.rowTitleFont
        titleLabel.maximumNumberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        if let stepper {
            stepper.minValue = range.lowerBound
            stepper.maxValue = range.upperBound
            stepper.increment = step
            stepper.valueWraps = false
            stepper.controlSize = .small
            stepper.target = self
            stepper.action = #selector(stepperChanged)
        }

        let descriptor = SettingsRowSymbols.icon(for: accessibilityLabel ?? title)
        let labels = SettingsLabelColumn(
            title: titleLabel, text: titleLabel,
            symbolName: symbolName ?? descriptor.name,
            symbolColor: symbolColor ?? descriptor.category.iconColor
        )
        var views: [NSView] = [labels, slider, valueLabel]
        if let stepper { views.append(stepper) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.distribution = .fill
        labels.setContentHuggingPriority(.required, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: SettingsMetrics.sliderValueWidth),
            labels.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, multiplier: 0.42),
        ]
        if let description {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            constraints += [
                label.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(stack.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        slider.setAccessibilityLabel(accessibilityLabel ?? title)
        stepper?.setAccessibilityLabel(accessibilityLabel ?? title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pushes a stored value into the slider, the stepper, and the readout.
    func setValue(_ value: Double) {
        slider.doubleValue = value
        stepper?.doubleValue = value
        valueLabel.stringValue = readout(for: value)
    }

    /// Enables or disables the slider and keeps assistive technologies in sync.
    func setEnabled(_ enabled: Bool) {
        slider.isEnabled = enabled
        stepper?.isEnabled = enabled
        valueLabel.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func readout(for value: Double) -> String {
        switch format {
        case .points: String(localized: "\(Int(value)) pt", comment: "Font size in points")
        case .percent: "\(Int((value * 100).rounded()))%"
        case .integer: String(Int(value.rounded()))
        case .ratio: value.formatted(.number.precision(.fractionLength(0...2))) + ":1"
        }
    }

    @objc private func sliderChanged() {
        let value: Double
        switch format {
        case .percent: value = slider.doubleValue
        case .ratio: value = (slider.doubleValue * 10).rounded() / 10
        case .points, .integer: value = slider.doubleValue.rounded()
        }
        valueLabel.stringValue = readout(for: value)
        stepper?.doubleValue = value
        onChange(value)
    }

    @objc private func stepperChanged() {
        guard let stepper else { return }
        let value = stepper.doubleValue
        slider.doubleValue = value
        valueLabel.stringValue = readout(for: value)
        onChange(value)
    }
}

/// The switch used by every boolean row, wired to a closure.
final class SettingsSwitch: NSSwitch {
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        controlSize = .small
        target = self
        action = #selector(toggled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }

    @objc private func toggled() {
        onChange(isOn)
    }
}

/// One entry in a ``SettingsPopUpButton``.
enum SettingsPopUpItem<Value> {
    case value(String, Value)
    /// A divider, for a picker whose first entry is set apart from the rest.
    case separator
}

/// A popup that maps its menu items back to typed values, so panes read and
/// write the selection without tracking indexes across dividers.
final class SettingsPopUpButton<Value: Equatable>: NSPopUpButton {
    private let values: [Value?]
    private let onChange: (Value) -> Void

    init(items: [SettingsPopUpItem<Value>], onChange: @escaping (Value) -> Void) {
        values = items.map { item in
            switch item {
            case let .value(_, value): value
            case .separator: nil
            }
        }
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        controlSize = .regular
        font = .systemFont(ofSize: NSFont.systemFontSize)
        for item in items {
            switch item {
            case let .value(title, _):
                let menuItem = NSMenuItem()
                // A title is set rather than passed to addItem so duplicate
                // family names — two fonts can share one — both survive.
                menuItem.title = title
                menu?.addItem(menuItem)
            case .separator:
                menu?.addItem(.separator())
            }
        }
        target = self
        action = #selector(selectionChanged)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Selects the item for `value`, leaving the popup alone when it offers no
    /// item for it — a hand-edited config can name a font this Mac lacks.
    func select(_ value: Value) {
        guard let index = values.firstIndex(of: value) else { return }
        selectItem(at: index)
    }

    @objc private func selectionChanged() {
        let index = indexOfSelectedItem
        guard values.indices.contains(index), let value = values[index] else { return }
        onChange(value)
    }
}
