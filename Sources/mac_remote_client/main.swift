import AppKit
import AVFoundation
import CoreMedia
import Foundation
import MacRemoteCore

final class ClientDelegate: NSObject, NSApplicationDelegate {
    private let transport: Transport
    private let modeLabel: String

    private var window: BorderlessWindow?
    private var videoView: VideoView?
    private var regionView: RegionView?
    private var remoteView: (any RemoteScreenView)?
    private var streamer: Streamer?
    private var inputSender: InputSender?
    private var keyframeTimer: Timer?
    private var fpsTimer: Timer?
    private var reconnectTimer: Timer?
    private var frameCount = 0
    private var lastFrameTime = Date()
    private var lastRemoteSize: CGSize = .zero
    private var isReconnecting = false
    private let useRegionMode: Bool

    init(transport: Transport, modeLabel: String, useRegionMode: Bool) {
        self.transport = transport
        self.modeLabel = modeLabel
        self.useRegionMode = useRegionMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let streamer = Streamer(transport: transport)
        transport.onState = { state in print("[transport] \(state)") }

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let win = BorderlessWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.title = "mac_remote"
        window = win

        if useRegionMode {
            let view = RegionView(frame: NSRect(origin: .zero, size: screenFrame.size))
            win.contentView = view
            regionView = view
            remoteView = view

            streamer.onRemoteSize = { [weak self, weak view] size in
                view?.remoteSize = size
                if size.width > 0, size.height > 0, size != self?.lastRemoteSize {
                    self?.lastRemoteSize = size
                    self?.streamer?.requestKeyframe()
                }
            }
            streamer.onRegionBatch = { [weak self, weak view] regions in
                guard let self else { return }
                self.frameCount += regions.count
                self.lastFrameTime = Date()
                if self.isReconnecting {
                    self.isReconnecting = false
                    print("Reconnected — video resumed")
                }
                view?.updateRegionBatch(regions: regions)
            }
        } else {
            let view = VideoView(frame: NSRect(origin: .zero, size: screenFrame.size))
            win.contentView = view
            videoView = view
            remoteView = view

            streamer.onRemoteSize = { [weak view] size in
                view?.remoteSize = size
            }
            streamer.onVideoFrame = { [weak self, weak view] sampleBuffer in
                guard let self, let view else { return }
                self.frameCount += 1
                self.lastFrameTime = Date()
                if self.isReconnecting {
                    self.isReconnecting = false
                    print("Reconnected — video resumed")
                }
                let layer = view.displayLayer
                DispatchQueue.main.async {
                    if layer.status == .failed {
                        print("displayLayer FAILED, flushing + marking decoder failed")
                        layer.flush()
                        self.streamer?.markDecoderFailed()
                        return
                    }
                    layer.enqueue(sampleBuffer)
                    if self.frameCount <= 3 {
                        print("enqueue #\(self.frameCount): layer.status=\(layer.status) frame=\(layer.frame)")
                    }
                }
            }
        }

        streamer.onFirstFrame = { [weak self] in
            DispatchQueue.main.async {
                self?.keyframeTimer?.invalidate()
                self?.keyframeTimer = nil
            }
        }

        streamer.onDisplayInfo = { [weak self] current, total in
            DispatchQueue.main.async {
                self?.remoteView?.showDisplayInfo(current: current, total: total)
            }
        }

        streamer.onUnlockResult = { [weak self] code in
            DispatchQueue.main.async {
                let msg: String
                switch code {
                case .unlocked: msg = "Unlocked"
                case .notLocked: msg = "Screen was not locked"
                case .stillLocked: msg = "Unlock failed — still locked. Secure Event Input may block synthetic keys; unlock once physically if this persists."
                case .unsupportedCharacter: msg = "Password contains characters unsupported by the US key mapping"
                case .error: msg = "Unlock error (empty password?)"
                }
                self?.remoteView?.showStatus(msg, hideAfter: 5)
            }
        }

        streamer.onLockState = { [weak self] isLocked in
            DispatchQueue.main.async {
                self?.remoteView?.showStatus(isLocked ? "Remote screen locked" : "Remote screen unlocked", hideAfter: 2.5)
            }
        }

        let sender = InputSender(streamer: streamer, view: remoteView!)
        sender.onCycleDisplay = { [weak streamer] in
            streamer?.sendSwitchDisplay(index: 255)
        }
        sender.onUnlockRequest = { [weak self] in
            DispatchQueue.main.async {
                self?.promptUnlockPassword()
            }
        }
        sender.install(onQuit: { NSApp.terminate(nil) })
        inputSender = sender

        streamer.start()
        self.streamer = streamer

        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKey()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        keyframeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.streamer?.sendHelloAndKeyframe()
        }

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fps = self.frameCount
            self.frameCount = 0
            if self.useRegionMode {
                print("fps: \(fps)")
            } else {
                let layer = self.videoView?.displayLayer
                print("fps: \(fps) layer.status=\(layer?.status ?? .unknown) frame=\(String(describing: layer?.frame))")
            }
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastFrameTime)
            if elapsed > 5 {
                if !self.isReconnecting {
                    self.isReconnecting = true
                    print("No video for \(Int(elapsed))s — requesting keyframe...")
                }
                self.streamer?.sendHelloAndKeyframe()
            }
        }
    }

    private func promptUnlockPassword() {
        let alert = NSAlert()
        alert.messageText = "Unlock remote screen"
        alert.informativeText = "Enter the login password of the remote Mac. It is sent over UDP (unencrypted) and typed into its lock screen."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        remoteView?.showStatus("Unlocking...", hideAfter: nil)
        streamer?.sendUnlock(password: field.stringValue)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSCursor.unhide()
    }
}

struct ClientConfig {
    var transport: Transport
    var modeLabel: String
    var debug: Bool
    var useRegionMode: Bool
}

func parseClientArgs() -> ClientConfig? {
    let args = CommandLine.arguments
    var host: String?
    var port: UInt16 = 42420
    var relayHost: String?
    var relayPort: UInt16 = 42430
    var user: String?
    var deviceId: String?
    var password: String?
    var debug = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--port":
            if i + 1 < args.count { port = UInt16(args[i + 1]) ?? port }
            i += 1
        case "--relay":
            if i + 1 < args.count {
                let parts = args[i + 1].split(separator: ":")
                relayHost = String(parts[0])
                if parts.count > 1 { relayPort = UInt16(parts[1]) ?? relayPort }
            }
            i += 1
        case "--user":
            if i + 1 < args.count { user = args[i + 1] }
            i += 1
        case "--device-id":
            if i + 1 < args.count { deviceId = args[i + 1] }
            i += 1
        case "--password":
            if i + 1 < args.count { password = args[i + 1] }
            i += 1
        case "--debug":
            debug = true
        default:
            if host == nil, !args[i].hasPrefix("--") {
                host = args[i]
            }
        }
        i += 1
    }

    if let rh = relayHost {
        guard let u = user, let id = deviceId else {
            print("--user and --device-id are required with --relay")
            return nil
        }
        var pass = password ?? ProcessInfo.processInfo.environment["MAC_REMOTE_PASSWORD"]
        if pass == nil {
            pass = SecureInput.readPassword(prompt: "Password for '\(u)': ")
        }
        let rt = RelayTransport(
            host: rh,
            controlPort: relayPort,
            role: .viewer(username: u, deviceId: id),
            secret: pass ?? ""
        )
        return ClientConfig(transport: rt, modeLabel: "relay \(rh):\(relayPort) as \(u) -> \(id)", debug: debug, useRegionMode: true)
    }

    guard let h = host else { return nil }
    let flow = UDPFlow(host: h, port: port)
    return ClientConfig(transport: flow, modeLabel: "direct \(h):\(port)", debug: debug, useRegionMode: false)
}

let clientConfig = parseClientArgs()

guard let cfg = clientConfig else {
    print("Usage:")
    print("  LAN:   mac_remote_client <host> [--port N] [--debug]")
    print("  Relay: mac_remote_client --relay <relay-host>[:port] --user <name> --device-id <id> [--password pass] [--debug]")
    exit(2)
}

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

Log.verbose = cfg.debug
print("Connecting via \(cfg.modeLabel)")

let app = NSApplication.shared
let delegate = ClientDelegate(transport: cfg.transport, modeLabel: cfg.modeLabel, useRegionMode: cfg.useRegionMode)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()