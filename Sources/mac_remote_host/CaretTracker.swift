import ApplicationServices
import AppKit
import MacRemoteCore

final class CaretTracker {
    private var timer: DispatchSourceTimer?
    private var lastCaretRect: CGRect = .zero
    private var lastVisible: Bool = false
    var onCaretUpdate: ((Bool, CGRect) -> Void)?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.checkCaret()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func checkCaret() {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            setCaretVisible(false)
            return
        }

        let focusedElement = focused as! AXUIElement

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let rangeValue = selectedRangeRef else {
            setCaretVisible(false)
            return
        }

        var cfRange = CFRange(location: 0, length: 0)
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange)

        var caretRange = CFRange(location: cfRange.location, length: 1)
        guard let rangeAXValue = AXValueCreate(.cfRange, &caretRange) else {
            setCaretVisible(false)
            return
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focusedElement, "AXBoundsForRange" as CFString, rangeAXValue, &boundsRef) == .success,
              let boundsValue = boundsRef else {
            setCaretVisible(false)
            return
        }

        var rect = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)

        if rect.width > 0 && rect.height > 0 {
            setCaretVisible(true, rect: rect)
        } else {
            setCaretVisible(false)
        }
    }

    private func setCaretVisible(_ visible: Bool, rect: CGRect = .zero) {
        let rectChanged = visible && (abs(rect.origin.x - lastCaretRect.origin.x) > 2 ||
                                      abs(rect.origin.y - lastCaretRect.origin.y) > 2 ||
                                      abs(rect.height - lastCaretRect.height) > 2)
        if visible != lastVisible || rectChanged {
            lastVisible = visible
            lastCaretRect = rect
            onCaretUpdate?(visible, rect)
        }
    }
}
