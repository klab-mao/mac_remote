import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import MacRemoteCore

/// Tracks screen lock state and performs unlock by typing the password into the
/// loginwindow password field via synthetic CGEvents.
///
/// IMPORTANT LIMITATION: when the loginwindow password field enables Secure
/// Event Input, synthetic keyboard events may be ignored by it (macOS has
/// tightened this in recent versions). We therefore self-verify: after typing,
/// we poll the lock state and report a result code so the user knows whether it
/// actually worked. The client shows this result.
enum ScreenLock {
    private static var locked = false
    private static var observers: [NSObjectProtocol] = []

    /// Call once at startup. Listens for lock/unlock distributed notifications.
    static func startTracking(onChange: @escaping (Bool) -> Void) {
        let center = DistributedNotificationCenter.default()
        let lock = center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
            locked = true
            onChange(true)
        }
        let unlock = center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
            locked = false
            onChange(false)
        }
        observers = [lock, unlock]
    }

    static var isLocked: Bool { locked }

    /// Wake displays (they are usually asleep while locked in a remote scenario).
    static func wakeDisplays() {
        // Wake via IOKit power assertion
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeUserIsActive as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "mac_remote unlock wake" as CFString,
            &assertionID
        )
        // Hold it briefly, then release (the loginwindow keeps the screen on once awake).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            IOPMAssertionRelease(assertionID)
        }
        // Also nudge with a null/hid event — posting any event counts as user activity.
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGEventSource.location(.cghidEventTap), mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
    }

    /// Attempt to unlock. Returns a result code; blocks up to ~4s while verifying.
    static func unlock(password: String) -> UnlockResultCode {
        guard !password.isEmpty else { return .error }

        // Authoritative check via the loginwindow session — our flag may be stale
        // (e.g. host started while already locked, or notification was missed).
        if sessionIsUnlocked() {
            locked = false
            return .notLocked
        }

        // 1. Wake the display so the password field is visible/focused.
        wakeDisplays()

        // 2. Small delay for the loginwindow to become interactive after wake.
        Thread.sleep(forTimeInterval: 0.6)

        // 3. Clear any stray input, then type the password.
        // Backspace a few times in case the field has focus with existing content.
        for _ in 0..<2 {
            postKey(keyCode: 51, keyDown: true)  // delete
            postKey(keyCode: 51, keyDown: false)
        }

        for ch in password.unicodeScalars {
            guard let keyCode = keyCode(for: ch) else {
                return .unsupportedCharacter
            }
            postKey(keyCode: keyCode, keyDown: true, shift: needsShift(ch))
            postKey(keyCode: keyCode, keyDown: false, shift: needsShift(ch))
            Thread.sleep(forTimeInterval: 0.02)
        }

        // 4. Press Return.
        Thread.sleep(forTimeInterval: 0.15)
        postKey(keyCode: 36, keyDown: true)  // return
        postKey(keyCode: 36, keyDown: false)

        // 5. Verify: poll lock state for up to 3s.
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if !locked {
                return .unlocked
            }
            // The distributed notification may lag; also re-check via CGSession copy.
            if sessionIsUnlocked() {
                locked = false
                return .unlocked
            }
        }
        return .stillLocked
    }

    /// Query the loginwindow session state directly (more authoritative than our flag).
    private static func sessionIsUnlocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let state = dict["CGSSessionScreenIsLocked"] as? Int else {
            return true  // key absent => not locked
        }
        return state == 0
    }

    private static func postKey(keyCode: CGKeyCode, keyDown: Bool, shift: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if shift {
            guard let flagsDown = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true) else { return }  // left shift
            flagsDown.post(tap: .cghidEventTap)
        }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
        if shift {
            event.flags = .maskShift
        }
        event.post(tap: .cghidEventTap)
        if shift {
            guard let flagsUp = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false) else { return }
            flagsUp.post(tap: .cghidEventTap)
        }
    }

    private static func needsShift(_ ch: Unicode.Scalar) -> Bool {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+{}|:\"<>?~".unicodeScalars.contains(ch)
    }

    /// US ANSI layout mapping for ASCII printable characters.
    private static func keyCode(for ch: Unicode.Scalar) -> CGKeyCode? {
        switch ch {
        case "a": return 0; case "b": return 11; case "c": return 8; case "d": return 2
        case "e": return 14; case "f": return 3; case "g": return 5; case "h": return 4
        case "i": return 34; case "j": return 38; case "k": return 40; case "l": return 37
        case "m": return 46; case "n": return 45; case "o": return 31; case "p": return 35
        case "q": return 12; case "r": return 15; case "s": return 1; case "t": return 17
        case "u": return 32; case "v": return 9; case "w": return 13; case "x": return 7
        case "y": return 16; case "z": return 6
        case "A": return 0; case "B": return 11; case "C": return 8; case "D": return 2
        case "E": return 14; case "F": return 3; case "G": return 5; case "H": return 4
        case "I": return 34; case "J": return 38; case "K": return 40; case "L": return 37
        case "M": return 46; case "N": return 45; case "O": return 31; case "P": return 35
        case "Q": return 12; case "R": return 15; case "S": return 1; case "T": return 17
        case "U": return 32; case "V": return 9; case "W": return 13; case "X": return 7
        case "Y": return 16; case "Z": return 6
        case "1": return 18; case "2": return 19; case "3": return 20; case "4": return 21
        case "5": return 23; case "6": return 22; case "7": return 26; case "8": return 28
        case "9": return 25; case "0": return 29
        case "!": return 18; case "@": return 19; case "#": return 20; case "$": return 21
        case "%": return 23; case "^": return 22; case "&": return 26; case "*": return 28
        case "(": return 25; case ")": return 29
        case "-": return 27; case "_": return 27
        case "=": return 24; case "+": return 24
        case "[": return 33; case "{": return 33
        case "]": return 30; case "}": return 30
        case "\\": return 42; case "|": return 42
        case ";": return 41; case ":": return 41
        case "'": return 39; case "\"": return 39
        case ",": return 43; case "<": return 43
        case ".": return 47; case ">": return 47
        case "/": return 44; case "?": return 44
        case "`": return 50; case "~": return 50
        case " ": return 49
        default: return nil
        }
    }
}
