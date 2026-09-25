import AppKit
import AVFoundation
import CoreMedia
import MacRemoteCore

final class VideoView: NSView {
    let displayLayer: AVSampleBufferDisplayLayer
    private let infoLabel: NSTextField
    private var infoHideTimer: Timer?

    var remoteSize: CGSize = CGSize(width: 1920, height: 1080) {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        infoLabel = NSTextField(labelWithString: "")
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer

        infoLabel.alignment = .center
        infoLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        infoLabel.textColor = .white
        infoLabel.isBezeled = false
        infoLabel.wantsLayer = true
        infoLabel.layer?.cornerRadius = 10
        infoLabel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        infoLabel.isHidden = true
        addSubview(infoLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
        infoLabel.sizeToFit()
        let labelSize = infoLabel.fittingSize
        infoLabel.frame = NSRect(
            x: (bounds.width - labelSize.width) / 2,
            y: (bounds.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    func showDisplayInfo(current: Int, total: Int) {
        infoLabel.stringValue = "Display \(current + 1) / \(total)"
        infoLabel.sizeToFit()
        needsLayout = true
        infoLabel.isHidden = false
        infoHideTimer?.invalidate()
        infoHideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.infoLabel.isHidden = true
        }
    }

    func normalizedPoint(for event: NSEvent) -> (nx: Float, ny: Float)? {
        let local = convert(event.locationInWindow, from: nil)
        var vw = bounds.width
        var vh = bounds.height
        if vw <= 0 || vh <= 0, let win = window {
            vw = win.contentView?.frame.width ?? 0
            vh = win.contentView?.frame.height ?? 0
        }
        guard vw > 0, vh > 0, remoteSize.width > 0, remoteSize.height > 0 else {
            print("normalizedPoint nil: bounds=\(bounds.size) winFrame=\(window?.frame.size ?? .zero) remoteSize=\(remoteSize) locInWin=\(event.locationInWindow)")
            return nil
        }
        let scale = min(vw / remoteSize.width, vh / remoteSize.height)
        let dw = remoteSize.width * scale
        let dh = remoteSize.height * scale
        let offX = (vw - dw) / 2
        let offY = (vh - dh) / 2
        let nx = (local.x - offX) / dw
        let nyTopLeft = 1.0 - (local.y - offY) / dh
        return (Float(min(max(nx, 0), 1)), Float(min(max(nyTopLeft, 0), 1)))
    }

    override var acceptsFirstResponder: Bool { true }
}

final class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class InputSender {
    private let streamer: Streamer
    private let view: VideoView
    private var monitors: [Any] = []
    private var captureDebugCount = 0
    var onCycleDisplay: (() -> Void)?

    init(streamer: Streamer, view: VideoView) {
        self.streamer = streamer
        self.view = view
    }

    func install(onQuit: @escaping () -> Void) {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }

            if event.type == .leftMouseDown, self.captureDebugCount == 0 {
                let ourWin = self.view.window
                print("monitor saw leftMouseDown: event.window=\(String(describing: event.window)) ourWindow=\(String(describing: ourWin)) match=\(ourWin === event.window) isKey=\(event.window?.isKeyWindow ?? false)")
            }

            guard let window = event.window, window === self.view.window, window.isKeyWindow else {
                if self.captureDebugCount == 0, event.type == .leftMouseDown {
                    print("input monitor: event not for our key window — not sending")
                }
                return event
            }

            if event.type == .keyDown, event.keyCode == 53 {
                onQuit()
                return nil
            }

            if event.type == .keyDown,
               event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift),
               let ch = event.charactersIgnoringModifiers, ch.lowercased() == "d" {
                self.onCycleDisplay?()
                return nil
            }

            if let packet = self.packet(from: event) {
                if self.captureDebugCount < 5 {
                    self.captureDebugCount += 1
                    print("input captured #\(self.captureDebugCount): kind=\(packet.kind) button=\(packet.button) nx=\(packet.nx) ny=\(packet.ny)")
                }
                self.streamer.sendInput(packet)
            }
            return nil
        }
        if let monitor {
            monitors.append(monitor)
        }
        NSCursor.hide()
    }

    private func packet(from event: NSEvent) -> InputPacket? {
        let flags = UInt32(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        let keyCode = UInt16(clamping: event.keyCode)
        let click = UInt32(clamping: event.clickCount)

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let n = view.normalizedPoint(for: event) else { return nil }
            let button: UInt8
            switch event.type {
            case .rightMouseDragged: button = 1
            case .otherMouseDragged: button = 2
            default: button = 0
            }
            return InputPacket(kind: .mouseMove, button: button, flags: flags, nx: n.nx, ny: n.ny)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let n = view.normalizedPoint(for: event) else { return nil }
            let button: UInt8 = event.type == .leftMouseDown ? 0 : (event.type == .rightMouseDown ? 1 : 2)
            return InputPacket(kind: .mouseDown, button: button, flags: flags, nx: n.nx, ny: n.ny, clickCount: click)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let n = view.normalizedPoint(for: event) else { return nil }
            let button: UInt8 = event.type == .leftMouseUp ? 0 : (event.type == .rightMouseUp ? 1 : 2)
            return InputPacket(kind: .mouseUp, button: button, flags: flags, nx: n.nx, ny: n.ny)

        case .scrollWheel:
            return InputPacket(kind: .scroll, flags: flags, dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY))

        case .keyDown:
            return InputPacket(kind: .keyDown, keyCode: keyCode, flags: flags)

        case .keyUp:
            return InputPacket(kind: .keyUp, keyCode: keyCode, flags: flags)

        case .flagsChanged:
            return InputPacket(kind: .flagsChanged, keyCode: keyCode, flags: flags)

        default:
            return nil
        }
    }
}