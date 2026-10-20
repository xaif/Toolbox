import SwiftUI

// The controls a tool's saved options (`ToolSettings`) are made of. On the tool's page they're the
// standard macOS controls. In the quick launcher, which wraps them in `KeyboardOptionsForm`, each one is a
// row of a Raycast-style form that works without the mouse.

// MARK: - Keyboard navigation

/// One option as the launcher's keyboard handling sees it.
struct OptionField: Equatable {
    enum Kind { case choice, toggle, slider, text }

    let id: String
    let kind: Kind
    /// Changes whenever the actions below would act differently, so the launcher picks up the new ones.
    /// That includes the value: the bindings they capture keep reading the value from when they were made.
    var signature = ""
    /// ←→: moves the value one step, or a long way with ⇧.
    var step: ((_ delta: Int, _ large: Bool) -> Void)?
    /// Space.
    var toggle: (() -> Void)?
    /// Typing: picks the first choice that starts with the typed text. False when none does.
    var select: ((String) -> Bool)?

    static func == (lhs: OptionField, rhs: OptionField) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.signature == rhs.signature
    }
}

/// The options on screen, in form order.
struct OptionFieldsKey: PreferenceKey {
    static let defaultValue: [OptionField] = []
    static func reduce(value: inout [OptionField], nextValue: () -> [OptionField]) {
        value += nextValue()
    }
}

/// Drives a tool's options from the keyboard in the quick launcher, like a Raycast form: ↑↓ or ⇥ move
/// between options, ←→ change the focused one, space ticks a checkbox and typing picks a matching choice.
@MainActor
@Observable
final class OptionsNavigator {
    /// The options on screen, in form order.
    var fields: [OptionField] = [] {
        didSet {
            // Options come and go with other options (Quality only for JPEG, say). When the focused one
            // goes, focus the one that took its place.
            guard focusedField == nil, !fields.isEmpty else { return }
            focus(fields[min(focusedIndex, fields.count - 1)].id)
        }
    }
    private(set) var focusedID: String?
    /// Bumped to give the keyboard back to the focused text field, say after the actions panel closes.
    private(set) var textFocusRequest = 0
    @ObservationIgnored private var focusedIndex = 0
    @ObservationIgnored private var submit: (EventModifiers) -> Void = { _ in }
    @ObservationIgnored private var cancel: () -> Void = {}
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var lastTyped = Date.distantPast

    var focusedField: OptionField? { fields.first { $0.id == focusedID } }
    var isEditingText: Bool { focusedField?.kind == .text }

    /// Starts over for a new form. ↩ calls `submit` (with `.shift` for ⇧↩), esc calls `cancel`.
    func reset(submit: @escaping (EventModifiers) -> Void, cancel: @escaping () -> Void) {
        fields = []
        focusedID = nil
        focusedIndex = 0
        self.submit = submit
        self.cancel = cancel
    }

    func focus(_ id: String) {
        if focusedID != id {
            focusedID = id
            typed = ""
        }
        if let index = fields.firstIndex(where: { $0.id == id }) { focusedIndex = index }
    }

    func restoreTextFocus() { textFocusRequest += 1 }

    func move(_ delta: Int) {
        guard !fields.isEmpty else { return }
        let index = fields.firstIndex { $0.id == focusedID }.map { $0 + delta } ?? 0
        focus(fields[min(max(index, 0), fields.count - 1)].id)
    }

    /// Handles a key pressed in the options. While a text field is focused, only the keys that leave it.
    func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            if press.phase == .down { submit(press.modifiers) }
        case .escape:
            if press.phase == .down { cancel() }
        case .upArrow:
            move(-1)
        case .downArrow:
            move(1)
        case .tab, KeyEquivalent("\u{19}"): // ⇧⇥ arrives as a back tab
            move(press.key == .tab && !press.modifiers.contains(.shift) ? 1 : -1)
        default:
            guard let field = focusedField, field.kind != .text else { return .ignored }
            return handle(press, in: field)
        }
        return .handled
    }

    private func handle(_ press: KeyPress, in field: OptionField) -> KeyPress.Result {
        let isTyping = !typed.isEmpty && Date.now.timeIntervalSince(lastTyped) < 1
        switch press.key {
        case .leftArrow, .rightArrow:
            field.step?(press.key == .leftArrow ? -1 : 1, press.modifiers.contains(.shift))
        case .space where !isTyping:
            field.toggle?()
        default:
            let typeable = CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces)
            guard let select = field.select, !press.characters.isEmpty,
                  press.characters.unicodeScalars.allSatisfy(typeable.contains),
                  press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            // Like a menu: letters typed in quick succession spell out the start of a choice.
            typed = isTyping ? typed + press.characters : press.characters
            lastTyped = .now
            if !select(typed), typed != press.characters {
                typed = press.characters
                _ = select(typed)
            }
        }
        return .handled
    }
}

/// Lays out a tool's options as launcher rows and lets `navigator` drive them.
struct KeyboardOptionsForm<Content: View>: View {
    let navigator: OptionsNavigator
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .font(.system(size: 13))
            .environment(navigator)
            .onPreferenceChange(OptionFieldsKey.self) { navigator.fields = $0 }
    }
}

/// Launcher rows put titles in a column on the left and controls to their right.
private enum OptionsLayout {
    static let titleWidth: CGFloat = 140
    static let spacing: CGFloat = 12
    static let rowPadding: CGFloat = 10
    /// Where the controls start.
    static let controlInset = rowPadding + titleWidth + spacing
}

/// An option in the launcher: its title, the control and, while it's focused, the keys that change it.
private struct OptionRow<Control: View>: View {
    let title: String?
    /// The fields in this row, usually just one.
    let ids: [String]
    var keys: [String] = []
    @ViewBuilder let control: Control

    @Environment(OptionsNavigator.self) private var navigator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isFocused = navigator.focusedID.map { ids.contains($0) } ?? false
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title ?? "")
                .foregroundStyle(.secondary)
                .frame(width: OptionsLayout.titleWidth, alignment: .trailing)
                .padding(.trailing, OptionsLayout.spacing)
            control
            Spacer(minLength: 8)
            // Always laid out, so the row doesn't reflow as the focus moves.
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap($0) } }
                .opacity(isFocused ? 1 : 0)
        }
        .padding(.horizontal, OptionsLayout.rowPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(isFocused ? LauncherPalette(scheme: colorScheme).highlight : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let id = ids.first { navigator.focus(id) } }
        .id(ids.first)
    }
}

/// A launcher text field for a number. It saves what you type right away, so ↩ runs with it.
private struct OptionTextField<Format: ParseableFormatStyle>: View
where Format.FormatOutput == String, Format.FormatInput: Comparable {
    let id: String
    @Binding var value: Format.FormatInput
    let format: Format
    let range: ClosedRange<Format.FormatInput>?

    @State private var text = ""
    @FocusState private var isEditing: Bool
    @Environment(OptionsNavigator.self) private var navigator

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isEditing)
            .onAppear { text = format.format(value) }
            .onChange(of: text) {
                guard let parsed = try? format.parseStrategy.parse(text) else { return }
                let clamped = range.map { min(max(parsed, $0.lowerBound), $0.upperBound) } ?? parsed
                if clamped != value { value = clamped }
            }
            .onChange(of: isEditing) {
                // Clicked into, or left: show the value that was saved.
                if isEditing { navigator.focus(id) } else { text = format.format(value) }
            }
            .onChange(of: navigator.focusedID, initial: true) { isEditing = navigator.focusedID == id }
            .onChange(of: navigator.textFocusRequest) { isEditing = navigator.focusedID == id }
            .onKeyPress(phases: [.down, .repeat]) { navigator.handle($0) }
            .preference(key: OptionFieldsKey.self, value: [OptionField(id: id, kind: .text)])
    }
}

// MARK: - Controls

/// One of an `OptionPicker`'s values and how it reads.
struct OptionChoice<Value: Hashable> {
    let value: Value
    let label: String
    var symbol: String?
    /// Separates this choice from the ones above it in the menu.
    var dividerBefore = false

    init(_ value: Value, _ label: String, symbol: String? = nil, dividerBefore: Bool = false) {
        self.value = value
        self.label = label
        self.symbol = symbol
        self.dividerBefore = dividerBefore
    }
}

/// A choice of one value. In the launcher ←→ step through the choices, ⇧←→ jump to the first or last,
/// and typing picks the one that starts with what's typed.
struct OptionPicker<Value: Hashable>: View {
    enum Style {
        case menu, segmented
        /// Radio buttons on the tool's page, a menu in the launcher.
        case radioGroup
    }

    let title: String
    @Binding var selection: Value
    var style: Style
    let choices: [OptionChoice<Value>]

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    init(_ title: String, selection: Binding<Value>, style: Style = .menu, choices: [OptionChoice<Value>]) {
        self.title = title
        _selection = selection
        self.style = style
        self.choices = choices
    }

    var body: some View {
        if navigator != nil {
            OptionRow(title: title, ids: [title], keys: ["←", "→"]) {
                if style == .segmented {
                    picker.labelsHidden().pickerStyle(.segmented).fixedSize()
                } else {
                    picker.labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .preference(key: OptionFieldsKey.self, value: [field])
        } else {
            switch style {
            case .menu: picker
            case .segmented: picker.pickerStyle(.segmented).fixedSize()
            case .radioGroup: picker.pickerStyle(.radioGroup)
            }
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                if choice.dividerBefore { Divider() }
                if let symbol = choice.symbol {
                    Label(choice.label, systemImage: symbol).tag(choice.value)
                } else {
                    Text(choice.label).tag(choice.value)
                }
            }
        }
    }

    private var field: OptionField {
        let choices = choices, selection = $selection
        let signature = choices.map(\.label).joined(separator: "\n") + "\n\(choices.firstIndex { $0.value == selection.wrappedValue } ?? -1)"
        return OptionField(
            id: title, kind: .choice, signature: signature,
            step: { delta, large in
                guard !choices.isEmpty else { return }
                let index = choices.firstIndex { $0.value == selection.wrappedValue } ?? 0
                let next = large ? (delta < 0 ? 0 : choices.count - 1) : min(max(index + delta, 0), choices.count - 1)
                selection.wrappedValue = choices[next].value
            },
            select: { typed in
                guard let match = choices.first(where: {
                    $0.label.range(of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
                }) else { return false }
                selection.wrappedValue = match.value
                return true
            })
    }
}

/// A checkbox. In the launcher, space ticks it.
struct OptionToggle: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        if navigator != nil {
            OptionRow(title: nil, ids: [title], keys: ["space"]) {
                Toggle(title, isOn: $isOn).toggleStyle(.checkbox)
            }
            .preference(key: OptionFieldsKey.self,
                        value: [OptionField(id: title, kind: .toggle, signature: "\(isOn)",
                                            toggle: { [isOn = $isOn] in isOn.wrappedValue.toggle() })])
        } else {
            Toggle(title, isOn: $isOn)
        }
    }
}

/// A value on a slider, with optional preset buttons below. In the launcher ←→ move it one step, and
/// ⇧←→ a tenth of the way or to the next preset.
struct OptionSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var presets: [Double]
    var minimumLabel: String?
    var maximumLabel: String?
    /// How a value reads, e.g. "85%".
    let format: (Double) -> String

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, presets: [Double] = [],
         minimumLabel: String? = nil, maximumLabel: String? = nil, format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.presets = presets
        self.minimumLabel = minimumLabel
        self.maximumLabel = maximumLabel
        self.format = format
    }

    var body: some View {
        if navigator != nil {
            OptionRow(title: title, ids: [title], keys: ["←", "→"]) {
                VStack(alignment: .leading, spacing: 8) {
                    slider
                    presetButtons
                }
            }
            .preference(key: OptionFieldsKey.self, value: [field])
        } else {
            LabeledContent(title) { slider }
            presetButtons
        }
    }

    private var slider: some View {
        HStack {
            if let minimumLabel { Text(minimumLabel).font(.caption).foregroundStyle(.secondary) }
            Slider(value: $value, in: range, step: step).frame(maxWidth: 260)
            if let maximumLabel { Text(maximumLabel).font(.caption).foregroundStyle(.secondary) }
            Text(format(value)).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var presetButtons: some View {
        if !presets.isEmpty {
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    Button(format(preset)) { value = preset }
                        .buttonStyle(.bordered)
                        .tint(abs(value - preset) < 0.001 ? .accentColor : nil)
                        .controlSize(.small)
                }
            }
        }
    }

    private var field: OptionField {
        let value = $value, range = range, step = step, presets = presets.sorted()
        let largeStep = max(step, ((range.upperBound - range.lowerBound) / 10 / step).rounded() * step)
        return OptionField(id: title, kind: .slider, signature: "\(value.wrappedValue)", step: { delta, large in
            let current = value.wrappedValue
            var next: Double
            if large, !presets.isEmpty {
                next = (delta > 0 ? presets.first { $0 > current + 0.001 } : presets.last { $0 < current - 0.001 }) ?? current
            } else {
                next = current + Double(delta) * (large ? largeStep : step)
                next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
            }
            value.wrappedValue = min(max(next, range.lowerBound), range.upperBound)
        })
    }
}

/// A number typed into a field, like a size in MB, kept within `range` when there is one.
struct OptionNumberField<Format: ParseableFormatStyle>: View
where Format.FormatOutput == String, Format.FormatInput: Strideable {
    typealias Value = Format.FormatInput

    let title: String
    @Binding var value: Value
    let format: Format
    var unit: String?
    var range: ClosedRange<Value>?
    /// Adds a stepper on the tool's page.
    var step: Value.Stride?
    var width: CGFloat

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    init(_ title: String, value: Binding<Value>, format: Format, unit: String? = nil, in range: ClosedRange<Value>? = nil,
         step: Value.Stride? = nil, width: CGFloat = 80) {
        self.title = title
        _value = value
        self.format = format
        self.unit = unit
        self.range = range
        self.step = step
        self.width = width
    }

    var body: some View {
        if navigator != nil {
            OptionRow(title: title, ids: [title]) {
                HStack {
                    OptionTextField(id: title, value: $value, format: format, range: range).frame(width: width)
                    if let unit { Text(unit).foregroundStyle(.secondary) }
                }
            }
        } else {
            LabeledContent(title) {
                HStack {
                    TextField(title, value: $value, format: format).textFieldStyle(.roundedBorder).frame(width: width)
                    if let unit { Text(unit).foregroundStyle(.secondary) }
                    if let step, let range { Stepper("", value: $value, in: range, step: step).labelsHidden() }
                }
            }
            .onChange(of: value) {
                if let range { value = min(max(value, range.lowerBound), range.upperBound) }
            }
        }
    }
}

/// A width × height in pixels. In the launcher, ↑↓ and ⇥ go from one field to the other.
struct OptionSizeFields: View {
    let title: String
    @Binding var width: Int
    @Binding var height: Int

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    private static let format = IntegerFormatStyle<Int>().grouping(.never)
    private static let range = 1...50_000

    init(_ title: String, width: Binding<Int>, height: Binding<Int>) {
        self.title = title
        _width = width
        _height = height
    }

    var body: some View {
        if navigator != nil {
            let ids = ["\(title) width", "\(title) height"]
            OptionRow(title: title, ids: ids) {
                HStack {
                    OptionTextField(id: ids[0], value: $width, format: Self.format, range: Self.range).frame(width: 80)
                    Text("×").foregroundStyle(.secondary)
                    OptionTextField(id: ids[1], value: $height, format: Self.format, range: Self.range).frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent(title) {
                HStack {
                    pixelField($width)
                    Text("×").foregroundStyle(.secondary)
                    pixelField($height)
                    Text("px").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pixelField(_ value: Binding<Int>) -> some View {
        TextField("px", value: value, format: Self.format)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .onChange(of: value.wrappedValue) {
                value.wrappedValue = min(max(value.wrappedValue, Self.range.lowerBound), Self.range.upperBound)
            }
    }
}

/// Options under one title, like checkboxes for the formats to save.
struct OptionGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if navigator != nil {
            // Checkbox rows leave the title column empty, so the group's title sits beside the first one.
            VStack(alignment: .leading, spacing: 2) { content }
                .overlay(alignment: .topLeading) {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .frame(width: OptionsLayout.titleWidth, height: 36, alignment: .trailing)
                        .padding(.leading, OptionsLayout.rowPadding)
                        .allowsHitTesting(false)
                }
        } else {
            LabeledContent(title) {
                HStack(spacing: 16) { content }
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// A line of help about the options.
struct OptionNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .optionIndent()
    }
}

extension View {
    /// In the launcher, lines this up with the option controls, right of their titles.
    func optionIndent() -> some View { modifier(OptionIndent()) }
}

private struct OptionIndent: ViewModifier {
    @Environment(OptionsNavigator.self) private var navigator: OptionsNavigator?

    func body(content: Content) -> some View {
        if navigator != nil {
            content
                .padding(.leading, OptionsLayout.controlInset)
                .padding(.trailing, OptionsLayout.rowPadding)
                .padding(.vertical, 4)
        } else {
            content
        }
    }
}
