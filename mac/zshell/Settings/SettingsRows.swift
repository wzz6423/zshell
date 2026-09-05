//
//  SettingsRows.swift
//  zshell
//

import AppKit

/// A settings row: label column on the left, control on the right. A row with
/// an explanation aligns its control to the top, the way macOS Settings does;
/// without one both sides center.
final class SettingsRow: NSView {
    private let descriptionLabel: NSTextField?

    init(title: String, description: String? = nil, control: NSView) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let textStack = NSStackView(views: [titleLabel])
        if let description {
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
            label.maximumNumberOfLines = 0
            textStack.addArrangedSubview(label)
            descriptionLabel = label
        } else {
            descriptionLabel = nil
        }
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        super.init(frame: .zero)

        let stack = NSStackView(views: [textStack, control])
        stack.orientation = .horizontal
        stack.alignment = description == nil ? .centerY : .top
        stack.spacing = SettingsMetrics.labelControlGap
        stack.distribution = .fill
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)

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
        onChange: @escaping (Double) -> Void
    ) {
        self.format = format
        self.onChange = onChange
        stepper = showsStepper ? NSStepper() : nil
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

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

        var views: [NSView] = [titleLabel, slider, valueLabel]
        if let stepper { views.append(stepper) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.distribution = .fill
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: SettingsMetrics.sliderValueWidth),
        ])

        if let accessibilityLabel {
            slider.setAccessibilityLabel(accessibilityLabel)
            stepper?.setAccessibilityLabel(accessibilityLabel)
        }
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

    private func readout(for value: Double) -> String {
        switch format {
        case .points: String(localized: "\(Int(value)) pt", comment: "Font size in points")
        case .percent: "\(Int((value * 100).rounded()))%"
        }
    }

    @objc private func sliderChanged() {
        let value = format == .points ? slider.doubleValue.rounded() : slider.doubleValue
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
        controlSize = .small
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
