import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H264Encoder {
    var onEncodedFrame: ((Data, Bool, Data, Data) -> Void)?

    private var session: VTCompressionSession?
    private var cachedSPS: Data?
    private var cachedPPS: Data?
    private var forceNextKeyframe = false
    private let lock = NSLock()

    private(set) var width: Int = 0
    private(set) var height: Int = 0

    func setup(width: Int, height: Int, fps: Int, bitrateMbps: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        print("Encoder setup: \(width)x\(height) \(bitrateMbps)Mbps...")
        var sessionRef: VTCompressionSession?
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: encodeOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionRef
        )
        guard status == noErr, let s = sessionRef else {
            throw EncoderError.createFailed(status)
        }
        session = s

        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_AverageBitRate: bitrateMbps * 1_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2.0
        ]
        for (key, value) in props {
            VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(s)
        guard prepareStatus == noErr else {
            throw EncoderError.prepareFailed(prepareStatus)
        }

        self.width = width
        self.height = height
        cachedSPS = nil
        cachedPPS = nil
        print("Encoder ready: \(width)x\(height) \(bitrateMbps)Mbps H.264 HW")
    }

    func encode(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let session else { return }
        var frameProps: CFDictionary?
        if forceNextKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceNextKeyframe = false
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func forceKeyFrame() {
        forceNextKeyframe = true
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    fileprivate func handleOutput(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sb = sampleBuffer, CMSampleBufferDataIsReady(sb) else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sb) else { return }

        var spsPtr: UnsafePointer<UInt8>?
        var ppsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsSize = 0
        var nalCount = 0
        var nalHeaderLength: Int32 = 0

        let sStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr,
            parameterSetSizeOut: &spsSize, parameterSetCountOut: &nalCount,
            nalUnitHeaderLengthOut: &nalHeaderLength)
        let pStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr,
            parameterSetSizeOut: &ppsSize, parameterSetCountOut: &nalCount,
            nalUnitHeaderLengthOut: &nalHeaderLength)
        guard sStatus == noErr, pStatus == noErr,
              let sps = spsPtr, let pps = ppsPtr else { return }

        let spsData = Data(bytes: sps, count: spsSize)
        let ppsData = Data(bytes: pps, count: ppsSize)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var bytes = [UInt8](repeating: 0, count: length)
        let copyStatus = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes)
        guard copyStatus == noErr else { return }

        let isKeyframe = Self.detectIDR(bytes)
        if isKeyframe {
            lock.lock()
            cachedSPS = spsData
            cachedPPS = ppsData
            lock.unlock()
        }

        onEncodedFrame?(Data(bytes), isKeyframe, spsData, ppsData)
    }

    static func detectIDR(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset + 4 <= bytes.count {
            let nalLen = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard nalLen > 0, offset + 4 + nalLen <= bytes.count else { break }
            let nalType = bytes[offset + 4] & 0x1F
            if nalType == 5 { return true }
            if nalType == 1 { return false }
            offset += 4 + nalLen
        }
        return false
    }

    enum EncoderError: Error {
        case createFailed(OSStatus)
        case prepareFailed(OSStatus)
    }
}

private func encodeOutputCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ infoFlags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.handleOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}