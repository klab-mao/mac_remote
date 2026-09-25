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

    private let flow: UDPFlow
    private let assembler = FrameAssembler()
    private var format: CMVideoFormatDescription?
    private var receivedFirstFrame = false

    init(flow: UDPFlow) {
        self.flow = flow
        flow.onPacket = { [weak self] header, payload in
            self?.handle(header: header, payload: payload)
        }
    }

    func start() {
        flow.start()
        flow.sendControl(.hello)
    }

    func sendInput(_ packet: InputPacket) {
        flow.send(type: .input, payload: packet.encode())
    }

    func requestKeyframe() {
        flow.sendControl(.keyframeRequest)
    }

    func sendHelloAndKeyframe() {
        flow.sendControl(.hello)
        flow.sendControl(.keyframeRequest)
    }

    func sendSwitchDisplay(index: UInt8) {
        flow.sendDatagram(Packetizer.controlPacket(.switchDisplay, extra: Data([index])))
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
            guard payload.count > 3 else { return }
            let spsLen = Int(payload[1])
            guard payload.count > 2 + spsLen else { return }
            let sps = payload.subdata(in: 2..<(2 + spsLen))
            let ppsLen = Int(payload[2 + spsLen])
            guard payload.count >= 3 + spsLen + ppsLen else { return }
            let pps = payload.subdata(in: (3 + spsLen)..<(3 + spsLen + ppsLen))
            updateFormat(sps: sps, pps: pps)
        case .displayInfo:
            guard payload.count >= 3 else { return }
            onDisplayInfo?(Int(payload[1]), Int(payload[2]))
        default:
            break
        }
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
        format = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        onRemoteSize?(CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height)))
        print("Format ready: \(dims.width)x\(dims.height)")
    }

    private func handleVideo(header: PacketHeader, payload: Data) {
        guard format != nil else {
            requestKeyframe()
            return
        }
        guard let avcc = assembler.push(header: header, payload: payload) else { return }
        guard let sampleBuffer = SampleBufferFactory.makeSampleBuffer(avcc, format: format!, frameId: header.frameId) else {
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
    private var oldestIncomplete: UInt32 = 0

    func push(header: PacketHeader, payload: Data) -> Data? {
        if header.frameId > oldestIncomplete + 512 {
            for (id, _) in frames where id < header.frameId - 512 {
                frames.removeValue(forKey: id)
            }
            oldestIncomplete = header.frameId
        }
        var frame = frames[header.frameId] ?? AssemblingFrame(fragCount: header.fragCount, parts: [:])
        frame.parts[header.fragIndex] = payload
        frames[header.frameId] = frame

        guard frame.parts.count == Int(frame.fragCount) else { return nil }
        var data = Data()
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