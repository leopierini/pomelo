// Maps click-mode key-downs to `NavKey`. Key codes rather than characters, so the digits and arrows sit in the same
// place on every keyboard layout. The keys only ever reach the key wheel panel: no key monitors, no event taps.
import AppKit
import Carbon.HIToolbox
import PomeloUIModel

extension NavKey {
    /// The navigation key for `keyCode`, or nil for any other key and for ⌘, ⌥ or ⌃ chords.
    ///
    /// Arrows, Tab, Return and keypad Enter, Escape, and the digits 1–8 on the top row and the keypad. Shift is
    /// allowed (some layouts, such as AZERTY, need it for the top-row digits); the function and numeric-pad flags
    /// that arrow keys carry are ignored.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        let code = Int(keyCode)
        switch code {
        case kVK_LeftArrow: self = .left
        case kVK_RightArrow: self = .right
        case kVK_UpArrow: self = .up
        case kVK_DownArrow: self = .down
        case kVK_Tab: self = .tab
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .enter
        case kVK_Escape: self = .escape
        default:
            guard let digit = Self.digitCodes.firstIndex(of: code) ?? Self.keypadDigitCodes.firstIndex(of: code)
            else { return nil }
            self = .digit(digit + 1)
        }
    }

    /// The top-row keys 1–8, in order (their codes are not contiguous).
    private static let digitCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                     kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]
    /// The keypad keys 1–8, in order.
    private static let keypadDigitCodes = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                                           kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8]
}
