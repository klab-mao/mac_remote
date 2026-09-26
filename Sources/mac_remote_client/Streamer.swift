import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation
import MacRemoteCore

final class Streamer {
    var onVideoFrame: ((CMSampleBuffer) -> Void)?
    var onRemoteSize: ((CGSize) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onDisplayInfo: ((Int, Int) -> Void)?
    var onUnlockResult: ((UnlockResultCode) -> Void)?
    var onLockState: ((Bool) -> Void)?

    private let transport: Transport
    private let assembler = FrameAssembler()
    private var format: CMVideoFormatDescription?
    private var receivedFirstFrame = false
    private var lastSPS: Data?
    private var lastPPS: Data?
    private let formatLock = NSLock()
    private var pingTimer: Timer?

    init(transport: Transport) {
        self.transport = transport
        transport.onPacket = { [weak self] header, payload in
            self?.handle(header: header, payload: payload)
        }
    }

    func start() {
        transport.start()
        transport.sendControl(.hello)
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.transport.sendControl(.ping)
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    func sendInput(_ packet: InputPacket) {
        transport.send(type: .input, payload: packet.encode())
    }

    func requestKeyframe() {
        transport.sendControl(.keyframeRequest)
    }

    func sendHelloAndKeyframe() {
        transport.sendControl(.hello)
        transport.sendControl(.keyframeRequest)
    }

    func sendSwitchDisplay(index: UInt8) {
        transport.sendDatagram(Packetizer.controlPacket(.switchDisplay, extra: Data([index])))
    }

    func sendUnlock(password: String) {
        transport.sendControl(.unlockRequest, extra: Data(password.utf8))
    }

    private func handle(header: PacketHeader, payload: Data) {
        switch header.type {
        case .video:
            handleVideo(header: header, payload: payload)
        case .control:
            handleControl(payload: payload)
        case .input:
            break
        }
    }

    private func handleControl(payload: Data) {
        guard let subType = ControlSubType(rawValue: payload.first ?? 255) else { return }
        switch subType {
        case .params:
            parseParams(payload)
        case .displayInfo:
            guard payload.count >= 3 else { return }
            onDisplayInfo?(Int(payload[1]), Int(payload[2]))
        case .unlockResult:
            guard payload.count >= 2, let code = UnlockResultCode(rawValue: payload[1]) else { return }
            onUnlockResult?(code)
        case .lockState:
            guard payload.count >= 2 else { return }
            onLockState?(payload[1] != 0)
        default:
            break
        }
    }

    private func parseParams(_ payload: Data) {
        guard payload.count > 3 else { return }
        let spsLen = Int(payload[1])
        guard payload.count > 2 + spsLen else { return }
        let sps = payload.subdata(in: 2..<(2 + spsLen))
        let ppsLen = Int(payload[2 + spsLen])
        guard payload.count >= 3 + spsLen + ppsLen else { return }
        let pps = payload.subdata(in: (3 + spsLen)..<(3 + spsLen + ppsLen))

        formatLock.lock()
        let unchanged = lastSPS == sps && lastPPS == pps && format != nil
        lastSPS = sps
        lastPPS = pps
        formatLock.unlock()
        if unchanged {
            Log.v("params unchanged, skipping format rebuild")
            return
        }
        updateFormat(sps: sps, pps: pps)
    }

    private func updateFormat(sps: Data, pps: Data) {
        var formatOut: CMVideoFormatDescription?
        var ok = false
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress, let ppsBase = ppsRaw.baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatOut
                )
                ok = status == noErr
            }
        }
        guard ok, let fmt = formatOut else {
            print("Failed to create format description")
            return
        }
        formatLock.lock()
        format = fmt
        formatLock.unlock()
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        onRemoteSize?(CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height)))
        print("Format ready: \(dims.width)x\(dims.height)")
    }

    private func handleVideo(header: PacketHeader, payload: Data) {
        formatLock.lock()
        let fmt = format
        formatLock.unlock()
        guard let format = fmt else {
            requestKeyframe()
            return
        }
        guard let avcc = assembler.push(header: header, payload: payload) else { return }
        guard let sampleBuffer = SampleBufferFactory.makeSampleBuffer(avcc, format: format, frameId: header.frameId) else {
            return
        }
        if !receivedFirstFrame {
            receivedFirstFrame = true
            onFirstFrame?()
        }
        onVideoFrame?(sampleBuffer)
    }
}

final class FrameAssembler {
    private struct AssemblingFrame {
        var fragCount: UInt16
        var parts: [UInt16: Data]
    }

    private var frames: [UInt32: AssemblingFrame] = [:]
    private var highestSeen: UInt32 = 0
    private let lock = NSLock()

    func push(header: PacketHeader, payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if header.frameId > highestSeen {
            highestSeen = header.frameId
            for (id, _) in frames where id < highestSeen &- 32 {
                frames.removeValue(forKey: id)
            }
        } else if highestSeen &- header.frameId > 256 {
            return nil
        }

        var frame = frames[header.frameId] ?? AssemblingFrame(fragCount: header.fragCount, parts: [:])
        frame.parts[header.fragIndex] = payload
        frames[header.frameId] = frame

        guard frame.parts.count == Int(frame.fragCount) else { return nil }
        var data = Data()
        data.reserveCapacity(Int(header.fragCount) * Packetizer.maxPayloadSize)
        for i in 0..<frame.fragCount {
            guard let part = frame.parts[i] else {
                frames.removeValue(forKey: header.frameId)
                return nil
            }
            data.append(part)
        }
        frames.removeValue(forKey: header.frameId)
        return data
    }
}

enum SampleBufferFactory {
    static func makeSampleBuffer(_ avcc: Data, format: CMVideoFormatDescription, frameId: UInt32) -> CMSampleBuffer? {
        guard let blockBuffer = makeBlockBuffer(avcc) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameId), timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else { return nil }
        CMSetAttachment(sb, key: kCMSampleAttachmentKey_DisplayImmediately, value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return sb
    }

    private static func makeBlockBuffer(_ data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        status = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return blockBuffer
    }
}