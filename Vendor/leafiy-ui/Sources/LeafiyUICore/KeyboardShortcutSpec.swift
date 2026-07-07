import Foundation

/// A global-hotkey shortcut: exactly two distinct modifiers plus one
/// alphanumeric key — the only shape the Leafiy apps register.
///
/// The type parses every historical on-disk format used by the app family
/// ("Command+Shift+V", "cmd+shift+v", "⌘⇧V") and serializes back to either
/// style, so each app keeps its stored format while sharing one editor UI
/// and one parser.
public struct KeyboardShortcutSpec: Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Identifiable, Sendable {
        case command = "Command"
        case shift = "Shift"
        case option = "Option"
        case control = "Control"

        public var id: String { rawValue }

        /// Menu-style symbol (⌘ ⇧ ⌥ ⌃).
        public var symbol: String {
            switch self {
            case .command: return "⌘"
            case .shift: return "⇧"
            case .option: return "⌥"
            case .control: return "⌃"
            }
        }

        /// Lowercase token used by fifi's stored format.
        public var shorthand: String {
            switch self {
            case .command: return "cmd"
            case .shift: return "shift"
            case .option: return "opt"
            case .control: return "ctrl"
            }
        }

        init?(token: some StringProtocol) {
            switch token.lowercased() {
            case "command", "cmd", "commandorcontrol":
                self = .command
            case "shift":
                self = .shift
            case "option", "opt", "alt":
                self = .option
            case "control", "ctrl":
                self = .control
            default:
                return nil
            }
        }
    }

    /// Invariant: `first != second` and `key` is one uppercase letter or
    /// digit. `init?` enforces it; direct mutation must preserve it
    /// (`ShortcutField` does, by swapping colliding modifiers).
    public var first: Modifier
    public var second: Modifier
    public var key: String

    public init?(first: Modifier, second: Modifier, key: String) {
        let normalizedKey = Self.normalizedKey(key)
        guard first != second, !normalizedKey.isEmpty else { return nil }
        self.first = first
        self.second = second
        self.key = normalizedKey
    }

    /// Accepts "Command+Shift+V", "cmd+shift+v", "⌘⇧V", and mixtures.
    /// More than two distinct modifiers keeps the first two; a missing key
    /// or fewer than two modifiers fails.
    public init?(parsing string: String) {
        let expanded = string
            .replacingOccurrences(of: "⌘", with: "Command+")
            .replacingOccurrences(of: "⇧", with: "Shift+")
            .replacingOccurrences(of: "⌥", with: "Option+")
            .replacingOccurrences(of: "⌃", with: "Control+")

        var modifiers: [Modifier] = []
        var key: String?
        for rawToken in expanded.split(separator: "+") {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let modifier = Modifier(token: token) {
                if !modifiers.contains(modifier) {
                    modifiers.append(modifier)
                }
            } else {
                guard key == nil else { return nil }
                key = token
            }
        }
        guard modifiers.count >= 2, let key else { return nil }
        self.init(first: modifiers[0], second: modifiers[1], key: key)
    }

    /// "Command+Shift+V" — daisy's stored format.
    public var canonicalDescription: String {
        "\(first.rawValue)+\(second.rawValue)+\(key)"
    }

    /// "cmd+shift+v" — fifi's stored format.
    public var shorthandDescription: String {
        "\(first.shorthand)+\(second.shorthand)+\(key.lowercased())"
    }

    /// "⌘⇧V" — for menus and labels.
    public var display: String {
        "\(first.symbol)\(second.symbol)\(key)"
    }

    /// First alphanumeric character, uppercased; empty when none exists.
    public static func normalizedKey(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(1))
    }
}
