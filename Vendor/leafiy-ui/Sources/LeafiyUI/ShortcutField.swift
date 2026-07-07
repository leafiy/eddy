import LeafiyUICore
import SwiftUI

/// The one shortcut editor used across the app family: two modifier menus
/// and a single-character key field, bound to a `KeyboardShortcutSpec`.
///
/// Picking a modifier already used on the other side swaps the two, so the
/// bound spec always stays valid. The key field coerces input to one
/// uppercase letter or digit and never commits an empty key.
public struct ShortcutField: View {
    @Binding private var spec: KeyboardShortcutSpec
    @State private var keyText: String = ""

    public init(spec: Binding<KeyboardShortcutSpec>) {
        self._spec = spec
    }

    public var body: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            modifierPicker(\.first, other: \.second)
            modifierPicker(\.second, other: \.first)
            TextField("V", text: $keyText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: LeafiyDesign.Size.shortcutKeyField)
                .onChange(of: keyText) { _, newValue in
                    let key = KeyboardShortcutSpec.normalizedKey(newValue)
                    if keyText != key {
                        keyText = key
                    }
                    if !key.isEmpty, spec.key != key {
                        spec.key = key
                    }
                }
        }
        .onAppear {
            keyText = spec.key
        }
        .onChange(of: spec.key) { _, newValue in
            if keyText != newValue {
                keyText = newValue
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcut")
    }

    private func modifierPicker(
        _ side: WritableKeyPath<KeyboardShortcutSpec, KeyboardShortcutSpec.Modifier>,
        other: WritableKeyPath<KeyboardShortcutSpec, KeyboardShortcutSpec.Modifier>
    ) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { spec[keyPath: side] },
                set: { newValue in
                    if newValue == spec[keyPath: other] {
                        spec[keyPath: other] = spec[keyPath: side]
                    }
                    spec[keyPath: side] = newValue
                }
            )
        ) {
            ForEach(KeyboardShortcutSpec.Modifier.allCases) { modifier in
                Text(modifier.rawValue).tag(modifier)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
