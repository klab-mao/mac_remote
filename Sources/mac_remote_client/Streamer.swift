import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation
import MacRemoteCore

final class Streamer {
    var onVideoFrame: ((CMSampleBuffer) -> Void)?
    var onRegion: ((Int, Int, Data) -> Void)?
    var onRegionBatch: (([(x: Int, y: Int, frameId: UInt32, jpegData: Data)]) -> Void)?
    var onRemoteSize: ((CGSize) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onDisplayInfo: ((Int, Int) -> Void)?
    var onUnlockResult: ((UnlockResultCode) -> Void)?
    var onLockState: ((Bool) -> Void)?
    var onFrameComplete: ((UInt32, Int) -> Void)?
    var onCursorImage: ((Data, Float, Float, Float, Float) -> Void)?
    var onCaretPosition: ((Bool, Float, Float, UInt16) -> Void)?

    private let transport: Transport
    private let assembler = FrameAssembler()
    private var format: CMVideoFormatDescription?
    private var receivedFirstFrame = false
    private var lastCodec: CodecType?
    private var lastParamSets: [Data] = []
    private let formatLock = NSLock()
    private var pingTimer: Timer?
    private var waitingForKeyframe = false
    private var assembledDebugCount = 0
    private var kfFragCount = 0
    private var nackSentFrames: Set<UInt32> = []
    private var maxTileSeq: UInt32 = 0
    private var recentTileSeqs: Set<UInt32> = []
    private var tileNackSent: Set<UInt32> = []
    private var tilesSinceLastNackCheck = 0

    // Adaptive bitrate state
    private var maxBitrate: Int = 10
    private var currentBitrate: Int = 10
    private var recentLossCount = 0
    private var recentTotalCount = 0
    private var lowLossStreak = 0
    private var lastSentBitrate = 0

    init(transport: Transport) {
        self.transport = transport
        transport.onPacket = { [weak self] header, payload in
            self?.handle(header: header, payload: payload)
        }
        assembler.onFrameLost = { [weak self] in
            self?.onFrameLost()
        }
        assembler.onNackNeeded = { [weak self] frameId, missing in
            self?.sendNack(frameId: frameId, missing: missing)
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

    private func sendNack(frameId: UInt32, missing: [UInt16]) {
        guard !nackSentFrames.contains(frameId) else { return }
        nackSentFrames.insert(frameId)
        if nackSentFrames.count > 20 {
            nackSentFrames = nackSentFrames.filter { $0 >= frameId &- 20 }
        }
        var extra = Data()
        extra.append(UInt8(frameId & 0xff))
        extra.append(UInt8((frameId >> 8) & 0xff))
        extra.append(UInt8((frameId >> 16) & 0xff))
        extra.append(UInt8((frameId >> 24) & 0xff))
        extra.append(UInt8(missing.count))
        for idx in missing {
            extra.append(UInt8(idx & 0xff))
            extra.append(UInt8(idx >> 8))
        }
        transport.sendControl(.nack, extra: extra)
        print("NACK: requesting \(missing.count) fragments for frameId=\(frameId)")
    }

    private func sendTileNack(_ missingSeqs: [UInt32]) {
        var extra = Data()
        extra.append(UInt8(missingSeqs.count))
        for seq in missingSeqs {
            extra.append(UInt8(seq & 0xff))
            extra.append(UInt8((seq >> 8) & 0xff))
            extra.append(UInt8((seq >> 16) & 0xff))
            extra.append(UInt8((seq >> 24) & 0xff))
        }
        transport.sendControl(.tileNack, extra: extra)
    }

    func markDecoderFailed() {
        waitingForKeyframe = true
        requestKeyframe()
        Log.v("decoder failed — waiting for keyframe, skipping P-frames")
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
        case .region:
            handleRegionPacket(header: header, payload: payload)
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
        case .screenSize:
            guard payload.count >= 5 else { return }
            let w = UInt16(payload[1]) | UInt16(payload[2]) << 8
            let h = UInt16(payload[3]) | UInt16(payload[4]) << 8
            onRemoteSize?(CGSize(width: CGFloat(w), height: CGFloat(h)))
        case .frameComplete:
            guard payload.count >= 7 else { return }
            let fid = UInt32(payload[1]) | UInt32(payload[2]) << 8 | UInt32(payload[3]) << 16 | UInt32(payload[4]) << 24
            let tileCount = Int(payload[5]) | Int(payload[6]) << 8
            onFrameComplete?(fid, tileCount)
        case .cursorShape:
            guard payload.count >= 17 else { return }
            let hotX = Float(bitPattern: UInt32(payload[1]) | UInt32(payload[2]) << 8 | UInt32(payload[3]) << 16 | UInt32(payload[4]) << 24)
            let hotY = Float(bitPattern: UInt32(payload[5]) | UInt32(payload[6]) << 8 | UInt32(payload[7]) << 16 | UInt32(payload[8]) << 24)
            let w = Float(bitPattern: UInt32(payload[9]) | UInt32(payload[10]) << 8 | UInt32(payload[11]) << 16 | UInt32(payload[12]) << 24)
            let h = Float(bitPattern: UInt32(payload[13]) | UInt32(payload[14]) << 8 | UInt32(payload[15]) << 16 | UInt32(payload[16]) << 24)
            let imageData = payload.subdata(in: 17..<payload.count)
            onCursorImage?(imageData, hotX, hotY, w, h)
        case .caretPosition:
            guard payload.count >= 8 else { return }
            let visible = payload[1] != 0
            let nx = Float(UInt16(payload[2]) | UInt16(payload[3]) << 8) / 65535.0
            let ny = Float(UInt16(payload[4]) | UInt16(payload[5]) << 8) / 65535.0
            let h = UInt16(payload[6]) | UInt16(payload[7]) << 8
            onCaretPosition?(visible, nx, ny, h)
        default:
            break
        }
    }

    private func parseParams(_ payload: Data) {
        guard payload.count > 3 else { return }
        guard let codec = CodecType(rawValue: payload[1]) else { return }
        let numParams = Int(payload[2])
        var offset = 3
        var paramSets: [Data] = []
        for _ in 0..<numParams {
            guard offset < payload.count else { return }
            let len = Int(payload[offset])
            offset += 1
            guard offset + len <= payload.count else { return }
            paramSets.append(payload.subdata(in: offset..<(offset + len)))
            offset += len
        }
        guard paramSets.count == numParams else { return }

        formatLock.lock()
        let unchanged = lastCodec == codec && lastParamSets == paramSets && format != nil
        lastCodec = codec
        lastParamSets = paramSets
        formatLock.unlock()
        if unchanged {
            Log.v("params unchanged, skipping format rebuild")
            return
        }
        updateFormat(codec: codec, paramSets: paramSets)
    }

    private func updateFormat(codec: CodecType, paramSets: [Data]) {
        var formatOut: CMVideoFormatDescription?
        var ok = false

        if codec == .hevc {
            guard paramSets.count == 3 else { return }
            paramSets[0].withUnsafeBytes { vpsRaw in
                paramSets[1].withUnsafeBytes { spsRaw in
                    paramSets[2].withUnsafeBytes { ppsRaw in
                        guard let vpsBase = vpsRaw.baseAddress,
                              let spsBase = spsRaw.baseAddress,
                              let ppsBase = ppsRaw.baseAddress else { return }
                        let pointers: [UnsafePointer<UInt8>] = [
                            vpsBase.assumingMemoryBound(to: UInt8.self),
                            spsBase.assumingMemoryBound(to: UInt8.self),
                            ppsBase.assumingMemoryBound(to: UInt8.self)
                        ]
                        let sizes = [paramSets[0].count, paramSets[1].count, paramSets[2].count]
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &formatOut
                        )
                        ok = status == noErr
                    }
                }
            }
        } else {
            guard paramSets.count == 2 else { return }
            paramSets[0].withUnsafeBytes { spsRaw in
                paramSets[1].withUnsafeBytes { ppsRaw in
                    guard let spsBase = spsRaw.baseAddress,
                          let ppsBase = ppsRaw.baseAddress else { return }
                    let pointers: [UnsafePointer<UInt8>] = [
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    let sizes = [paramSets[0].count, paramSets[1].count]
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
        print("Format ready: \(dims.width)x\(dims.height) \(codec == .hevc ? "HEVC" : "H.264")")
    }

    private func handleVideo(header: PacketHeader, payload: Data) {
        let isKeyframe = (header.flags & 1) != 0
        if isKeyframe {
            kfFragCount += 1
            if kfFragCount <= 3 || kfFragCount % 50 == 0 {
                print("kf frag #\(kfFragCount): idx=\(header.fragIndex)/\(header.fragCount) frameId=\(header.frameId)")
            }
        }
        if waitingForKeyframe {
            guard isKeyframe else {
                Log.v("skipping P-frame while waiting for keyframe (frameId=\(header.frameId))")
                return
            }
            waitingForKeyframe = false
            Log.v("keyframe received, resuming decode (frameId=\(header.frameId))")
        }
        formatLock.lock()
        let fmt = format
        formatLock.unlock()
        guard let format = fmt else {
            requestKeyframe()
            return
        }
        recentTotalCount += 1
        guard let avcc = assembler.push(header: header, payload: payload) else { return }
        if isKeyframe || assembledDebugCount < 5 {
            assembledDebugCount += 1
            print("assembled #\(assembledDebugCount): \(avcc.count) bytes, keyframe=\(isKeyframe), frameId=\(header.frameId)")
        }
        guard let sampleBuffer = SampleBufferFactory.makeSampleBuffer(avcc, format: format, frameId: header.frameId) else {
            return
        }
        if !receivedFirstFrame {
            receivedFirstFrame = true
            onFirstFrame?()
        }
        onVideoFrame?(sampleBuffer)
    }

    private func handleRegionPacket(header: PacketHeader, payload: Data) {
        let seq = header.frameId
        recentTileSeqs.insert(seq)
        if seq > maxTileSeq {
            maxTileSeq = seq
        }
        tilesSinceLastNackCheck += 1
        if tilesSinceLastNackCheck >= 10 {
            tilesSinceLastNackCheck = 0
            if maxTileSeq > 20 {
                var missing: [UInt32] = []
                let scanStart = maxTileSeq > 200 ? maxTileSeq - 200 : 1
                let scanEnd = maxTileSeq - 5
                var s = scanStart
                while s < scanEnd && missing.count < 20 {
                    if !recentTileSeqs.contains(s) {
                        missing.append(s)
                    }
                    s &+= 1
                }
                if !missing.isEmpty {
                    sendTileNack(missing)
                }
            }
        }
        if recentTileSeqs.count > 300 {
            let cutoff = maxTileSeq &- 300
            recentTileSeqs = recentTileSeqs.filter { $0 > cutoff }
        }
        if tileNackSent.count > 300 {
            let cutoff = maxTileSeq &- 300
            tileNackSent = tileNackSent.filter { $0 > cutoff }
        }

        var regions: [(x: Int, y: Int, frameId: UInt32, jpegData: Data)] = []
        var offset = 0
        while offset + 16 <= payload.count {
            let frameId = UInt32(payload[offset]) | UInt32(payload[offset + 1]) << 8 | UInt32(payload[offset + 2]) << 16 | UInt32(payload[offset + 3]) << 24
            offset += 4
            let x = UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8
            let y = UInt16(payload[offset + 2]) | UInt16(payload[offset + 3]) << 8
            offset += 8
            let jpegLen = Int(UInt32(payload[offset]) | UInt32(payload[offset + 1]) << 8 | UInt32(payload[offset + 2]) << 16 | UInt32(payload[offset + 3]) << 24)
            offset += 4
            guard offset + jpegLen <= payload.count, jpegLen > 0 else { break }
            let jpegData = payload.subdata(in: offset..<(offset + jpegLen))
            offset += jpegLen
            if !receivedFirstFrame {
                receivedFirstFrame = true
                onFirstFrame?()
            }
            regions.append((Int(x), Int(y), frameId, jpegData))
        }
        if !regions.isEmpty {
            if let onRegionBatch = onRegionBatch {
                onRegionBatch(regions)
            } else {
                for (x, y, _, jpeg) in regions {
                    onRegion?(x, y, jpeg)
                }
            }
        } else if payload.count > 0 {
            print("[streamer] region packet: 0 regions from \(payload.count) bytes")
        }
    }

    // Called by FrameAssembler when a frame is dropped due to missing fragments.
    private func onFrameLost() {
        recentLossCount += 1
        requestKeyframe()
        adaptBitrate()
    }

    private func adaptBitrate() {
        guard recentTotalCount >= 30 else { return }
        let lossRate = Double(recentLossCount) / Double(recentTotalCount)

        if lossRate > 0.15 {
            // High loss — reduce bitrate aggressively
            let newBitrate = max(5, Int(Double(currentBitrate) * 0.75))
            if newBitrate != currentBitrate {
                currentBitrate = newBitrate
                sendBitrateChange()
                lowLossStreak = 0
            }
        } else if lossRate < 0.03 {
            lowLossStreak += 1
            if lowLossStreak >= 60 && currentBitrate < maxBitrate {
                let newBitrate = min(maxBitrate, Int(Double(currentBitrate) * 1.15))
                if newBitrate != currentBitrate {
                    currentBitrate = newBitrate
                    sendBitrateChange()
                }
                lowLossStreak = 0
            }
        } else {
            lowLossStreak = 0
        }

        // Reset window
        if recentTotalCount >= 60 {
            recentLossCount = 0
            recentTotalCount = 0
        }
    }

    private func sendBitrateChange() {
        guard currentBitrate != lastSentBitrate else { return }
        lastSentBitrate = currentBitrate
        transport.sendControl(.setBitrate, extra: Data([UInt8(currentBitrate)]))
        Log.v("adaptive bitrate: \(currentBitrate)Mbps (loss rate tracked)")
    }

    func setMaxBitrate(_ mbps: Int) {
        maxBitrate = mbps
        if currentBitrate > mbps {
            currentBitrate = mbps
            sendBitrateChange()
        }
    }
}

final class FrameAssembler {
    private struct AssemblingFrame {
        var fragCount: UInt16
        var parts: [UInt16: Data]
        var isKeyframe: Bool
    }

    var onFrameLost: (() -> Void)?
    var onNackNeeded: ((UInt32, [UInt16]) -> Void)?

    private var frames: [UInt32: AssemblingFrame] = [:]
    private var highestSeen: UInt32 = 0
    private let lock = NSLock()

    func push(header: PacketHeader, payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let isKeyframe = (header.flags & 1) != 0

        if header.frameId > highestSeen {
            highestSeen = header.frameId
            // When a new keyframe arrives, drop all older incomplete frames immediately
            if isKeyframe {
                for (id, frame) in frames where id < header.frameId && frame.parts.count < Int(frame.fragCount) {
                    if frame.isKeyframe {
                        onFrameLost?()
                    }
                    frames.removeValue(forKey: id)
                }
            }
            // Drop stale frames — P-frames after 5 IDs, keyframes after 30 IDs (NACK recovery needs time)
            for (id, frame) in frames where id < highestSeen &- 5 {
                if frame.isKeyframe && id >= highestSeen &- 30 { continue }
                if frame.parts.count < Int(frame.fragCount) {
                    onFrameLost?()
                }
                frames.removeValue(forKey: id)
            }
        } else if highestSeen &- header.frameId > 256 {
            return nil
        }

        var frame = frames[header.frameId] ?? AssemblingFrame(fragCount: header.fragCount, parts: [:], isKeyframe: isKeyframe)
        frame.parts[header.fragIndex] = payload
        frames[header.frameId] = frame

        // NACK: if this is a keyframe and we have some fragments but not all, request missing
        if isKeyframe && frame.parts.count >= Int(frame.fragCount) / 4 && frame.parts.count < Int(frame.fragCount) {
            let missing = (0..<frame.fragCount).filter { frame.parts[$0] == nil }
            if !missing.isEmpty && missing.count <= 60 {
                onNackNeeded?(header.frameId, missing)
            }
        }

        guard frame.parts.count == Int(frame.fragCount) else { return nil }
        var data = Data()
        data.reserveCapacity(Int(header.fragCount) * Packetizer.maxPayloadSize)
        for i in 0..<frame.fragCount {
            guard let part = frame.parts[i] else {
                frames.removeValue(forKey: header.frameId)
                onFrameLost?()
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