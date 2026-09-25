import Foundation
import CoreGraphics
import MacRemoteCore

enum InputInjector {
    static func perform(_ p: InputPacket, originX: CGFloat, originY: CGFloat, screenW: CGFloat, screenH: CGFloat) {
        let x = originX + CGFloat(p.nx) * screenW
        let y = originY + CGFloat(p.ny) * screenH
        let cgFlags = CGEventFlags(rawValue: UInt64(p.flags))

        switch p.kind {
        case .mouseMove, .mouseDown, .mouseUp:
            let button = mouseButton(p.button)
            let type: CGEventType
            switch p.kind {
            case .mouseDown:
                type = downType(p.button)
            case .mouseUp:
                type = upType(p.button)
            default:
                type = moveType(p.button)
            }
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: button) else { return }
            event.flags = cgFlags
            event.setIntegerValueField(.mouseEventClickState, value: Int64(p.clickCount))
            event.post(tap: .cghidEventTap)

        case .scroll:
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(p.dy),
                wheel2: Int32(p.dx),
                wheel3: 0
            ) else { return }
            event.post(tap: .cghidEventTap)

        case .keyDown, .keyUp, .flagsChanged:
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: p.keyCode, keyDown: p.kind == .keyDown) else { return }
            event.type = p.kind == .keyDown ? .keyDown : (p.kind == .keyUp ? .keyUp : .flagsChanged)
            event.flags = cgFlags
            event.post(tap: .cghidEventTap)
        }
    }

    private static func mouseButton(_ b: UInt8) -> CGMouseButton {
        switch b {
        case 0: return .left
        case 1: return .right
        default: return .center
        }
    }

    private static func downType(_ b: UInt8) -> CGEventType {
        switch b {
        case 0: return .leftMouseDown
        case 1: return .rightMouseDown
        default: return .otherMouseDown
        }
    }

    private static func upType(_ b: UInt8) -> CGEventType {
        switch b {
        case 0: return .leftMouseUp
        case 1: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    private static func moveType(_ b: UInt8) -> CGEventType {
        let button = mouseButton(b)
        let dragging = CGEventSource.buttonState(.combinedSessionState, button: button)
        if dragging {
            switch b {
            case 0: return .leftMouseDragged
            case 1: return .rightMouseDragged
            default: return .otherMouseDragged
            }
        }
        return .mouseMoved
    }
}