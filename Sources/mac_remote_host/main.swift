import AppKit
import CoreGraphics
import Foundation
import MacRemoteCore
import ScreenCaptureKit

final class HostEngine {
    private let port: UInt16
    private let fps: Int
    private let bitrateMbps: Int
    private let displayIndex: Int
    private let clientTimeout: TimeInterval
    private let relay: RelaySpec?

    private let capture = CaptureEngine()
    private let encoder = H264Encoder()
    private let stateLock = NSLock()
    private var transport: Transport?
    private var frameId: UInt32 = 0
    private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var lastClientActivity: Date = .distantPast
    private var clientTimedOut = false

    struct RelaySpec {
        var host: String
        var controlPort: UInt16
        var deviceId: String
        var password: String
    }

    init(port: UInt16, fps: Int, bitrateMbps: Int, displayIndex: Int, clientTimeout: TimeInterval, relay: RelaySpec?) {
        self.port = port
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.displayIndex = displayIndex
        self.clientTimeout = clientTimeout
        self.relay = relay
    }

    func start() {
        ScreenLock.startTracking { [weak self] locked in
            print("Screen \(locked ? "locked" : "unlocked")")
            self?.sendLockState()
        }

        encoder.onEncodedFrame = { [weak self] data, isKeyframe, sps, pps in
            self?.handleEncoded(data: data, isKeyframe: isKeyframe, sps: sps, pps: pps)
        }

        capture.onFrame = { [weak self] pixelBuffer, time in
            self?.encoder.encode(pixelBuffer, time: time)
        }

        if let relay {
            let rt = RelayTransport(
                host: relay.host,
                controlPort: relay.controlPort,
                role: .host(deviceId: relay.deviceId),
                secret: relay.password
            )
            attachTransport(rt, label: "relay")
            rt.start()
            print("Host connecting to relay \(relay.host):\(relay.controlPort) as device '\(relay.deviceId)'")
        } else {
            let listener = UDPListener(port: port)
            listener.onFlow = { [weak self] flow in
                self?.attachTransport(flow, label: "client")
            }
            listener.start()
            print("Host listening on UDP port \(port)")
        }

        Task {
            do {
                let (w, h) = try await self.capture.prepare(displayIndex: self.displayIndex, fps: self.fps)
                self.currentDisplayID = self.capture.displays[self.capture.currentIndex].displayID
                try self.encoder.setup(width: w, height: h, fps: self.fps, bitrateMbps: self.bitrateMbps)
                try await self.capture.beginStream()
            } catch {
                print("Startup failed: \(error)")
                exit(1)
            }
        }
    }

    private func attachTransport(_ t: Transport, label: String) {
        print("\(label) connected")
        t.onPacket = { [weak self] header, payload in
            self?.handlePacket(header: header, payload: payload)
        }
        t.onState = { state in
            Log.v("[\(label)] \(state)")
        }
        t.start()
        stateLock.lock()
        transport = t
        stateLock.unlock()
    }

    private func handlePacket(header: PacketHeader, payload: Data) {
        stateLock.lock()
        lastClientActivity = Date()
        let wasTimedOut = clientTimedOut
        clientTimedOut = false
        stateLock.unlock()
        if wasTimedOut {
            print("Client activity resumed, video unpaused")
            encoder.forceKeyFrame()
        }

        switch header.type {
        case .control:
            handleControl(payload: payload)
        case .input:
            handleInput(payload: payload)
        case .video:
            break
        }
    }

    private func handleControl(payload: Data) {
        guard let subType = ControlSubType(rawValue: payload.first ?? 255) else { return }
        switch subType {
        case .hello:
            sendControl { $0.sendControl(.helloAck) }
            encoder.forceKeyFrame()
            sendDisplayInfo()
            print("Client registered, keyframe forced")
        case .keyframeRequest:
            encoder.forceKeyFrame()
        case .switchDisplay:
            guard payload.count >= 2 else { return }
            let requested = Int(payload[1])
            let target = requested == 255 ? (capture.currentIndex + 1) % max(capture.displayCount, 1) : requested
            switchDisplay(to: target)
        case .unlockRequest:
            guard payload.count >= 2 else { return }
            let password = String(data: payload.subdata(in: 1..<payload.count), encoding: .utf8) ?? ""
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = ScreenLock.unlock(password: password)
                print("Unlock attempt result: \(result)")
                self?.sendUnlockResult(result)
            }
        case .ping:
            sendControl { $0.sendControl(.pong) }
        default:
            break
        }
    }

    private func sendControl(_ block: (Transport) -> Void) {
        stateLock.lock()
        let t = transport
        stateLock.unlock()
        guard let t else { return }
        block(t)
    }

    private func sendUnlockResult(_ result: UnlockResultCode) {
        var payload = Data()
        payload.append(ControlSubType.unlockResult.rawValue)
        payload.append(result.rawValue)
        sendControl { $0.send(type: .control, payload: payload) }
    }

    private func sendLockState() {
        var payload = Data()
        payload.append(ControlSubType.lockState.rawValue)
        payload.append(ScreenLock.isLocked ? 1 : 0)
        sendControl { $0.send(type: .control, payload: payload) }
    }

    private func sendDisplayInfo() {
        var payload = Data()
        payload.append(ControlSubType.displayInfo.rawValue)
        payload.append(UInt8(capture.currentIndex))
        payload.append(UInt8(capture.displayCount))
        sendControl { $0.send(type: .control, payload: payload) }
    }

    private var inputDebugCount = 0

    private func handleInput(payload: Data) {
        guard let p = InputPacket.decode(payload) else { return }
        let bounds = CGDisplayBounds(currentDisplayID)
        let gx = bounds.minX + CGFloat(p.nx) * bounds.width
        let gy = bounds.minY + CGFloat(p.ny) * bounds.height
        if inputDebugCount < 5 {
            inputDebugCount += 1
            Log.v("input #\(inputDebugCount): kind=\(p.kind) button=\(p.button) nx=\(p.nx) ny=\(p.ny) -> global (\(Int(gx)),\(Int(gy)))")
            if inputDebugCount == 1, !AXIsProcessTrusted() {
                print("!!! Accessibility NOT granted — CGEvent.post will silently fail. Grant it in System Settings > Privacy & Security > Accessibility for this binary, then restart the host.")
            }
        }
        InputInjector.perform(
            p,
            originX: bounds.minX,
            originY: bounds.minY,
            screenW: bounds.width,
            screenH: bounds.height
        )
    }

    private func switchDisplay(to index: Int) {
        guard capture.displayCount > 0 else { return }
        Task {
            do {
                let (w, h, did) = try await self.capture.switchDisplay(index)
                self.currentDisplayID = did
                if w != self.encoder.width || h != self.encoder.height {
                    try self.encoder.setup(width: w, height: h, fps: self.fps, bitrateMbps: self.bitrateMbps)
                }
                self.encoder.forceKeyFrame()
                self.sendDisplayInfo()
                print("Switched to display \(self.capture.currentIndex)/\(self.capture.displayCount - 1)")
            } catch {
                print("Switch display failed: \(error)")
            }
        }
    }

    private var encodedDebugCount = 0

    private func handleEncoded(data: Data, isKeyframe: Bool, sps: Data, pps: Data) {
        stateLock.lock()
        let t = transport
        let elapsed = Date().timeIntervalSince(lastClientActivity)
        let wasTimedOut = clientTimedOut
        if elapsed > clientTimeout {
            clientTimedOut = true
        }
        stateLock.unlock()

        if elapsed > clientTimeout {
            if !wasTimedOut {
                print("Client inactive for \(Int(elapsed))s — pausing video (timeout=\(Int(clientTimeout))s)")
            }
            return
        }

        guard let t else { return }

        if encodedDebugCount < 3 {
            encodedDebugCount += 1
            Log.v("encoded #\(encodedDebugCount): \(data.count) bytes, keyframe=\(isKeyframe), frags=\((data.count + 1299) / 1300)")
        }

        if isKeyframe {
            var params = Data()
            params.append(ControlSubType.params.rawValue)
            params.append(UInt8(sps.count))
            params.append(sps)
            params.append(UInt8(pps.count))
            params.append(pps)
            t.send(type: .control, payload: params)
        }

        stateLock.lock()
        frameId &+= 1
        let fid = frameId
        stateLock.unlock()
        let datagrams = Packetizer.fragment(data, frameId: fid, isKeyframe: isKeyframe)
        for d in datagrams {
            t.sendDatagram(d)
        }
    }
}

func parseArgs() -> (port: UInt16, fps: Int, bitrateMbps: Int, displayIndex: Int, clientTimeout: TimeInterval, relay: HostEngine.RelaySpec?, debug: Bool) {
    var port: UInt16 = 42420
    var fps = 60
    var bitrate = 25
    var displayIndex = 0
    var clientTimeout: TimeInterval = 10
    var relayHost: String?
    var relayPort: UInt16 = 42430
    var deviceId: String?
    var password: String?
    var debug = false
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--port":
            if i + 1 < args.count { port = UInt16(args[i + 1]) ?? port }
            i += 1
        case "--fps":
            if i + 1 < args.count { fps = Int(args[i + 1]) ?? fps }
            i += 1
        case "--bitrate":
            if i + 1 < args.count { bitrate = Int(args[i + 1]) ?? bitrate }
            i += 1
        case "--display":
            if i + 1 < args.count { displayIndex = Int(args[i + 1]) ?? displayIndex }
            i += 1
        case "--client-timeout":
            if i + 1 < args.count { clientTimeout = Double(args[i + 1]) ?? clientTimeout }
            i += 1
        case "--relay":
            if i + 1 < args.count {
                let parts = args[i + 1].split(separator: ":")
                relayHost = String(parts[0])
                if parts.count > 1 { relayPort = UInt16(parts[1]) ?? relayPort }
            }
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
            break
        }
        i += 1
    }

    var relay: HostEngine.RelaySpec?
    if let rh = relayHost {
        guard let id = deviceId else {
            print("--device-id is required with --relay")
            exit(2)
        }
        var pass = password ?? ProcessInfo.processInfo.environment["MAC_REMOTE_PASSWORD"]
        if pass == nil {
            pass = SecureInput.readPassword(prompt: "Device password for '\(id)': ")
        }
        relay = HostEngine.RelaySpec(host: rh, controlPort: relayPort, deviceId: id, password: pass ?? "")
    }

    return (port, fps, bitrate, displayIndex, clientTimeout, relay, debug)
}

let config = parseArgs()
Log.verbose = config.debug

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screenOK = CGPreflightScreenCaptureAccess()
if !screenOK {
    _ = CGRequestScreenCaptureAccess()
}
print("Screen Recording permission: \(screenOK ? "GRANTED" : "NOT GRANTED (capture will fail until enabled in System Settings > Privacy & Security > Screen Recording, then restart)")")

let axOK = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
print("Accessibility permission: \(axOK ? "GRANTED" : "NOT GRANTED (mouse/keyboard injection will silently fail until enabled in System Settings > Privacy & Security > Accessibility, then restart)")")

let engine = HostEngine(
    port: config.port,
    fps: config.fps,
    bitrateMbps: config.bitrateMbps,
    displayIndex: config.displayIndex,
    clientTimeout: config.clientTimeout,
    relay: config.relay
)
engine.start()

app.run()
