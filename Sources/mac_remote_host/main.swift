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
    private let codec: CodecType

    private let capture = CaptureEngine()
    private let encoder = H264Encoder()
    private let stateLock = NSLock()
    private var transport: Transport?
    private var listener: UDPListener?
    private var frameId: UInt32 = 0
    private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var lastClientActivity: Date = .distantPast
    private var clientTimedOut = false
    private var keyframeBuffer: [UInt32: [Data]] = [:]
    private let regionEncoder = RegionEncoder()
    private var useRegionMode = false

    struct RelaySpec {
        var host: String
        var controlPort: UInt16
        var deviceId: String
        var password: String
    }

    init(port: UInt16, fps: Int, bitrateMbps: Int, displayIndex: Int, clientTimeout: TimeInterval, relay: RelaySpec?, codec: CodecType) {
        self.port = port
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.displayIndex = displayIndex
        self.clientTimeout = clientTimeout
        self.relay = relay
        self.codec = codec
    }

    func start() {
        ScreenLock.startTracking { [weak self] locked in
            print("Screen \(locked ? "locked" : "unlocked")")
            self?.sendLockState()
        }

        useRegionMode = relay != nil

        encoder.onEncodedFrame = { [weak self] data, isKeyframe, paramSets in
            self?.handleEncoded(data: data, isKeyframe: isKeyframe, paramSets: paramSets)
        }

        regionEncoder.onRegion = { [weak self] fid, x, y, w, h, jpeg in
            self?.handleRegion(frameId: fid, x: x, y: y, w: w, h: h, jpeg: jpeg)
        }

        regionEncoder.onFrameComplete = { [weak self] fid, count in
            self?.sendFrameComplete(frameId: fid, tileCount: count)
        }

        capture.onFrame = { [weak self] pixelBuffer, time in
            guard let self else { return }
            if self.useRegionMode {
                self.regionEncoder.encode(pixelBuffer)
            } else {
                self.encoder.encode(pixelBuffer, time: time)
            }
        }

        if let relay {
            let rt = RelayTransport(
                host: relay.host,
                controlPort: relay.controlPort,
                role: .host(deviceId: relay.deviceId),
                secret: relay.password
            )
            attachTransport(rt, label: "relay")
            print("Host connecting to relay \(relay.host):\(relay.controlPort) as device '\(relay.deviceId)'")
        } else {
            let l = UDPListener(port: port)
            l.onFlow = { [weak self] flow in
                self?.attachTransport(flow, label: "client")
            }
            l.start()
            listener = l
            print("Host listening on UDP port \(port)")
        }

        Task {
            while true {
                do {
                    let (w, h) = try await self.capture.prepare(displayIndex: self.displayIndex, fps: self.fps)
                    self.currentDisplayID = self.capture.displays[self.capture.currentIndex].displayID
                    if self.useRegionMode {
                        self.regionEncoder.setup(width: w, height: h)
                        stateLock.lock()
                        self.pendingScreenSize = true
                        stateLock.unlock()
                    } else {
                        try self.encoder.setup(width: w, height: h, fps: self.fps, bitrateMbps: self.bitrateMbps, codec: self.codec)
                    }
                    try await self.capture.beginStream()
                    break
                } catch {
                    print("Startup failed: \(error) — retrying in 5s")
                    _ = CGRequestScreenCaptureAccess()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func attachTransport(_ t: Transport, label: String) {
        print("\(label) connected")
        t.onPacket = { [weak self] header, payload in
            self?.handlePacket(header: header, payload: payload)
        }
        t.onState = { state in
            print("[\(label)] \(state)")
        }
        t.start()
        stateLock.lock()
        transport = t
        stateLock.unlock()
    }

    private var pendingScreenSize = false
    private func handlePacket(header: PacketHeader, payload: Data) {
        stateLock.lock()
        lastClientActivity = Date()
        let wasTimedOut = clientTimedOut
        clientTimedOut = false
        stateLock.unlock()
        if wasTimedOut {
            print("Client activity resumed, video unpaused")
            if useRegionMode {
                regionEncoder.forceFullFrame()
            } else {
                encoder.forceKeyFrame()
            }
        }

        switch header.type {
        case .control:
            handleControl(payload: payload)
        case .input:
            handleInput(payload: payload)
        case .video, .region:
            break
        }
    }

    private func handleControl(payload: Data) {
        guard let subType = ControlSubType(rawValue: payload.first ?? 255) else { return }
        switch subType {
        case .hello:
            sendControl { $0.sendControl(.helloAck) }
            if useRegionMode {
                stateLock.lock()
                pendingScreenSize = true
                stateLock.unlock()
                regionEncoder.forceFullFrame()
            } else {
                encoder.forceKeyFrame()
            }
            sendDisplayInfo()
            print("Client registered, \(useRegionMode ? "full frame forced" : "keyframe forced")")
        case .keyframeRequest:
            if useRegionMode {
                regionEncoder.forceFullFrame()
            } else {
                encoder.forceKeyFrame()
            }
        case .setBitrate:
            guard payload.count >= 2 else { return }
            let mbps = Int(payload[1])
            guard mbps >= 5 && mbps <= 100 else { return }
            encoder.setBitrate(mbps)
            print("Client requested bitrate: \(mbps)Mbps")
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
        case .nack:
            handleNack(payload: payload)
        case .tileNack:
            handleTileNack(payload: payload)
        default:
            break
        }
    }

    private func handleNack(payload: Data) {
        guard payload.count >= 5 else { return }
        let frameId = payload.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) }
        let count = Int(payload[5])
        guard payload.count >= 6 + count * 2 else { return }
        stateLock.lock()
        let frags = keyframeBuffer[frameId]
        let t = transport
        stateLock.unlock()
        guard let frags, let t else { return }
        var retransmitted = 0
        for i in 0..<count {
            let idx = UInt16(payload[6 + i*2]) | UInt16(payload[7 + i*2]) << 8
            if Int(idx) < frags.count {
                t.sendDatagram(frags[Int(idx)])
                retransmitted += 1
            }
        }
        if retransmitted > 0 {
            Log.v("NACK: retransmitted \(retransmitted)/\(count) fragments for frameId=\(frameId)")
        }
    }

    private func handleTileNack(payload: Data) {
        guard payload.count >= 2 else { return }
        let count = Int(payload[1])
        guard count > 0, payload.count >= 2 + count * 4 else { return }
        stateLock.lock()
        let t = transport
        stateLock.unlock()
        guard let t else { return }
        var retransmitted = 0
        for i in 0..<count {
            let base = 2 + i * 4
            let seq = UInt32(payload[base]) | UInt32(payload[base + 1]) << 8 | UInt32(payload[base + 2]) << 16 | UInt32(payload[base + 3]) << 24
            stateLock.lock()
            let cached = tileCache[seq]
            stateLock.unlock()
            if let cached = cached {
                t.send(type: .region, frameId: seq, payload: cached)
                retransmitted += 1
            }
        }
        if retransmitted > 0 {
            Log.v("TileNACK: retransmitted \(retransmitted)/\(count) tiles")
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

        if p.kind == .mouseMove {
            let localX = Int(CGFloat(p.nx) * bounds.width)
            let localY = Int(CGFloat(p.ny) * bounds.height)
            regionEncoder.updateCursor(x: localX, y: localY)
        }
    }

    private func switchDisplay(to index: Int) {
        guard capture.displayCount > 0 else { return }
        Task {
            do {
                let (w, h, did) = try await self.capture.switchDisplay(index)
                self.currentDisplayID = did
                if self.useRegionMode {
                    self.regionEncoder.setup(width: w, height: h)
                    stateLock.lock()
                    self.pendingScreenSize = true
                    stateLock.unlock()
                    self.regionEncoder.forceFullFrame()
                } else {
                    if w != self.encoder.width || h != self.encoder.height {
                        try self.encoder.setup(width: w, height: h, fps: self.fps, bitrateMbps: self.bitrateMbps, codec: self.codec)
                    }
                    self.encoder.forceKeyFrame()
                }
                self.sendDisplayInfo()
                print("Switched to display \(self.capture.currentIndex)/\(self.capture.displayCount - 1)")
            } catch {
                print("Switch display failed: \(error)")
            }
        }
    }

    private var encodedDebugCount = 0

    private func handleEncoded(data: Data, isKeyframe: Bool, paramSets: [Data]) {
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

        if encodedDebugCount < 5 {
            encodedDebugCount += 1
            print("encoded #\(encodedDebugCount): \(data.count) bytes, keyframe=\(isKeyframe)")
        }

        if isKeyframe {
            var params = Data()
            params.append(ControlSubType.params.rawValue)
            params.append(codec.rawValue)
            params.append(UInt8(paramSets.count))
            for ps in paramSets {
                params.append(UInt8(ps.count))
                params.append(ps)
            }
            t.send(type: .control, payload: params)
        }

        stateLock.lock()
        frameId &+= 1
        let fid = frameId
        stateLock.unlock()
        let datagrams = Packetizer.fragment(data, frameId: fid, isKeyframe: isKeyframe)
        if isKeyframe {
            stateLock.lock()
            keyframeBuffer[fid] = datagrams
            if keyframeBuffer.count > 3 {
                let oldest = keyframeBuffer.keys.min() ?? fid
                keyframeBuffer.removeValue(forKey: oldest)
            }
            stateLock.unlock()
        }
        for d in datagrams {
            t.sendDatagram(d)
        }
    }

    private var packetSeq: UInt32 = 0
    private var tileCache: [UInt32: Data] = [:]
    private var tileCacheOrder: [UInt32] = []
    private let tileCacheLimit = 1000

    private func handleRegion(frameId: UInt32, x: UInt16, y: UInt16, w: UInt16, h: UInt16, jpeg: Data) {
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
                print("Client inactive for \(Int(elapsed))s! — pausing video (timeout=\(Int(clientTimeout))s)")
            }
            return
        }

        guard let t else { return }

        stateLock.lock()
        let needSize = pendingScreenSize
        pendingScreenSize = false
        stateLock.unlock()
        if needSize {
            sendScreenSize()
        }

        stateLock.lock()
        packetSeq &+= 1
        let seq = packetSeq
        stateLock.unlock()

        var payload = Data()
        payload.appendLE(frameId)
        payload.appendLE(x)
        payload.appendLE(y)
        payload.appendLE(w)
        payload.appendLE(h)
        payload.appendLE(UInt32(jpeg.count))
        payload.append(jpeg)
        t.send(type: .region, frameId: seq, payload: payload)
        stateLock.lock()
        tileCache[seq] = payload
        tileCacheOrder.append(seq)
        if tileCacheOrder.count > tileCacheLimit {
            let evict = tileCacheOrder.removeFirst()
            tileCache.removeValue(forKey: evict)
        }
        stateLock.unlock()
    }

    private func sendScreenSize() {
        let w = capture.currentWidth
        let h = capture.currentHeight
        guard w > 0, h > 0 else { return }
        var payload = Data()
        payload.append(ControlSubType.screenSize.rawValue)
        payload.appendLE(UInt16(w))
        payload.appendLE(UInt16(h))
        sendControl { $0.send(type: .control, payload: payload) }
    }

    private func sendFrameComplete(frameId: UInt32, tileCount: Int) {
        var payload = Data()
        payload.append(ControlSubType.frameComplete.rawValue)
        payload.appendLE(frameId)
        payload.appendLE(UInt16(tileCount))
        sendControl { $0.send(type: .control, payload: payload) }
    }
}

func parseArgs() -> (port: UInt16, fps: Int, bitrateMbps: Int, displayIndex: Int, clientTimeout: TimeInterval, relay: HostEngine.RelaySpec?, codec: CodecType, debug: Bool) {
    var port: UInt16 = 42420
    var fps = 30
    var bitrate = 40
    var displayIndex = 0
    var clientTimeout: TimeInterval = 10
    var relayHost: String?
    var relayPort: UInt16 = 42430
    var deviceId: String?
    var password: String?
    var codec: CodecType = .h264
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
        case "--codec":
            if i + 1 < args.count {
                let c = args[i + 1].lowercased()
                codec = c == "hevc" || c == "h265" ? .hevc : .h264
            }
            i += 1
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

    return (port, fps, bitrate, displayIndex, clientTimeout, relay, codec, debug)
}

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

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
    relay: config.relay,
    codec: config.codec
)
engine.start()

app.run()
