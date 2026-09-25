import AppKit
import AVFoundation
import CoreMedia
import Foundation
import MacRemoteCore

final class ClientDelegate: NSObject, NSApplicationDelegate {
    private let host: String
    private let port: UInt16

    private var window: BorderlessWindow?
    private var videoView: VideoView?
    private var streamer: Streamer?
    private var inputSender: InputSender?
    private var keyframeTimer: Timer?
    private var fpsTimer: Timer?
    private var frameCount = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let flow = UDPFlow(host: host, port: port)
        let streamer = Streamer(flow: flow)

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let win = BorderlessWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = VideoView(frame: NSRect(origin: .zero, size: screenFrame.size))
        win.contentView = view
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.title = "mac_remote"

        window = win
        videoView = view

        streamer.onRemoteSize = { [weak view] size in
            view?.remoteSize = size
        }

        streamer.onVideoFrame = { [weak self, weak view] sampleBuffer in
            guard let self, let view else { return }
            self.frameCount += 1
            let layer = view.displayLayer
            DispatchQueue.main.async {
                layer.enqueue(sampleBuffer)
                if layer.status == .failed {
                    layer.flush()
                    self.streamer?.requestKeyframe()
                }
            }
        }

        streamer.onFirstFrame = { [weak self] in
            DispatchQueue.main.async {
                self?.keyframeTimer?.invalidate()
                self?.keyframeTimer = nil
            }
        }

        streamer.onDisplayInfo = { [weak view] current, total in
            DispatchQueue.main.async {
                view?.showDisplayInfo(current: current, total: total)
            }
        }

        let sender = InputSender(streamer: streamer, view: view)
        sender.onCycleDisplay = { [weak streamer] in
            streamer?.sendSwitchDisplay(index: 255)
        }
        sender.install(onQuit: { NSApp.terminate(nil) })
        inputSender = sender

        streamer.start()
        self.streamer = streamer

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
            print("fps: \(fps)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSCursor.unhide()
    }
}


func parseClientArgs() -> (host: String, port: UInt16)? {
    let args = CommandLine.arguments
    var host: String?
    var port: UInt16 = 42420
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--port":
            if i + 1 < args.count { port = UInt16(args[i + 1]) ?? port }
            i += 1
        default:
            if host == nil, !args[i].hasPrefix("--") {
                host = args[i]
            }
        }
        i += 1
    }
    guard let h = host else { return nil }
    return (h, port)
}

let clientConfig = parseClientArgs()

guard let cfg = clientConfig else {
    print("Usage: mac_remote_client <host> [--port N]")
    exit(2)
}

let app = NSApplication.shared
let delegate = ClientDelegate(host: cfg.host, port: cfg.port)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()