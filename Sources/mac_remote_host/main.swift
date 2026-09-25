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

    private let capture = CaptureEngine()
    private let encoder = H264Encoder()
    private var listener: UDPListener?
    private var activeFlow: UDPFlow?
    private var frameId: UInt32 = 0
    private var currentDisplayID: CGDirectDisplayID = CGMainDisplayID()

    init(port: UInt16, fps: Int, bitrateMbps: Int, displayIndex: Int) {
        self.port = port
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.displayIndex = displayIndex
    }

    func start() {
        let listener = UDPListener(port: port)
        listener.onFlow = { [weak self] flow in
            self?.handleFlow(flow)
        }
        listener.start()
        self.listener = listener
        print("Host listening on UDP port \(port)")

        encoder.onEncodedFrame = { [weak self] data, isKeyframe, sps, pps in
            self?.handleEncoded(data: data, isKeyframe: isKeyframe, sps: sps, pps: pps)
        }

        capture.onFrame = { [weak self] pixelBuffer, time in
            self?.encoder.encode(pixelBuffer, time: time)
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

    private func handleFlow(_ flow: UDPFlow) {
        print("Client flow connected")
        flow.onPacket = { [weak self] header, payload in
            guard let self else { return }
            switch header.type {
            case .control:
                self.handleControl(payload: payload, flow: flow)
            case .input:
                self.handleInput(payload: payload)
            case .video:
                break
            }
        }
        flow.start()
    }

    private func handleControl(payload: Data, flow: UDPFlow) {
        guard let subType = ControlSubType(rawValue: payload.first ?? 255) else { return }
        switch subType {
        case .hello:
            activeFlow = flow
            flow.sendControl(.helloAck)
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
        default:
            break
        }
    }

    private var inputDebugCount = 0

    private func handleInput(payload: Data) {
        guard let p = InputPacket.decode(payload) else { return }
        let bounds = CGDisplayBounds(currentDisplayID)
        let gx = bounds.minX + CGFloat(p.nx) * bounds.width
        let gy = bounds.minY + CGFloat(p.ny) * bounds.height
        if inputDebugCount < 5 {
            inputDebugCount += 1
            print("input #\(inputDebugCount): kind=\(p.kind) button=\(p.button) nx=\(p.nx) ny=\(p.ny) -> global (\(Int(gx)),\(Int(gy)))")
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

    private func sendDisplayInfo() {
        guard let flow = activeFlow else { return }
        var payload = Data()
        payload.append(ControlSubType.displayInfo.rawValue)
        payload.append(UInt8(capture.currentIndex))
        payload.append(UInt8(capture.displayCount))
        flow.send(type: .control, frameId: 0, fragIndex: 0, fragCount: 1, payload: payload)
    }

    private var encodedDebugCount = 0

    private func handleEncoded(data: Data, isKeyframe: Bool, sps: Data, pps: Data) {
        guard let flow = activeFlow else { return }

        if encodedDebugCount < 3 {
            encodedDebugCount += 1
            print("encoded #\(encodedDebugCount): \(data.count) bytes, keyframe=\(isKeyframe), frags=\((data.count + 1299) / 1300)")
        }

        if isKeyframe {
            var params = Data()
            params.append(ControlSubType.params.rawValue)
            params.append(UInt8(sps.count))
            params.append(sps)
            params.append(UInt8(pps.count))
            params.append(pps)
            flow.send(type: .control, frameId: 0, fragIndex: 0, fragCount: 1, payload: params)
        }

        frameId &+= 1
        let datagrams = Packetizer.fragment(data, frameId: frameId, isKeyframe: isKeyframe)
        for d in datagrams {
            flow.sendDatagram(d)
        }
    }
}

func parseArgs() -> (port: UInt16, fps: Int, bitrateMbps: Int, displayIndex: Int) {
    var port: UInt16 = 42420
    var fps = 60
    var bitrate = 25
    var displayIndex = 0
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
        default:
            break
        }
        i += 1
    }
    return (port, fps, bitrate, displayIndex)
}

let config = parseArgs()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screenOK = CGPreflightScreenCaptureAccess()
if !screenOK {
    _ = CGRequestScreenCaptureAccess()
}
print("Screen Recording permission: \(screenOK ? "GRANTED" : "NOT GRANTED (capture will fail until enabled in System Settings > Privacy & Security > Screen Recording, then restart)")")

let axOK = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
print("Accessibility permission: \(axOK ? "GRANTED" : "NOT GRANTED (mouse/keyboard injection will silently fail until enabled in System Settings > Privacy & Security > Accessibility, then restart)")")

let engine = HostEngine(port: config.port, fps: config.fps, bitrateMbps: config.bitrateMbps, displayIndex: config.displayIndex)
engine.start()

app.run()
