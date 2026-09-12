import Foundation

/// A keyboard shortcut parsed from a user-typed spec like "cmd+shift+4".
/// Key codes are the macOS virtual key codes (kVK_*) for a US layout;
/// KnockAgent turns this into CGEvents.
public struct KeyCombo: Equatable {
    public enum Modifier: Hashable {
        case command, shift, option, control
    }

    public let keyCode: UInt16
    public let modifiers: Set<Modifier>

    public init(keyCode: UInt16, modifiers: Set<Modifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Parses "+"-separated tokens: any number of modifiers plus exactly one
    /// key. Case-insensitive; whitespace around tokens is ignored.
    public static func parse(_ spec: String) -> KeyCombo? {
        var modifiers = Set<Modifier>()
        var keyCode: UInt16?
        for rawToken in spec.split(separator: "+", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            if let modifier = modifierNames[token] {
                modifiers.insert(modifier)
            } else if let code = keyNames[token] {
                guard keyCode == nil else { return nil } // two keys, e.g. "cmd+c+v"
                keyCode = code
            } else {
                return nil
            }
        }
        guard let keyCode else { return nil }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    private static let modifierNames: [String: Modifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "alt": .option, "opt": .option, "option": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    private static let keyNames: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103,
        "f10": 109, "f12": 111, "f4": 118, "f2": 120, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
