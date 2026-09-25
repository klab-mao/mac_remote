import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "mac_remote.capture")

    private(set) var displays: [SCDisplay] = []
    private(set) var currentIndex: Int = 0
    private(set) var fps: Int = 60
    private(set) var currentWidth: Int = 0
    private(set) var currentHeight: Int = 0

    var displayCount: Int { displays.count }

    func prepare(displayIndex: Int, fps: Int) async throws -> (width: Int, height: Int) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw CaptureError.noDisplay
        }
        displays = content.displays
        self.fps = fps
        currentIndex = min(max(displayIndex, 0), displays.count - 1)
        let d = displays[currentIndex]
        currentWidth = CGDisplayPixelsWide(d.displayID)
        currentHeight = CGDisplayPixelsHigh(d.displayID)
        print("Available displays: \(displays.count)")
        for (i, dd) in displays.enumerated() {
            let bounds = CGDisplayBounds(dd.displayID)
            print("  [\(i)] id=\(dd.displayID) \(Int(bounds.width))x\(Int(bounds.height)) origin=(\(Int(bounds.minX)),\(Int(bounds.minY)))")
        }
        return (currentWidth, currentHeight)
    }

    func beginStream() async throws {
        try await startStream()
    }

    func switchDisplay(_ index: Int) async throws -> (width: Int, height: Int, displayID: CGDirectDisplayID) {
        guard !displays.isEmpty else { throw CaptureError.noDisplay }
        let target = min(max(index, 0), displays.count - 1)
        try await stream?.stopCapture()
        stream = nil
        currentIndex = target
        let d = displays[target]
        currentWidth = CGDisplayPixelsWide(d.displayID)
        currentHeight = CGDisplayPixelsHigh(d.displayID)
        try await startStream()
        return (currentWidth, currentHeight, d.displayID)
    }

    private func startStream() async throws {
        let display = displays[currentIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let pixelW = CGDisplayPixelsWide(display.displayID)
        let pixelH = CGDisplayPixelsHigh(display.displayID)
        currentWidth = pixelW
        currentHeight = pixelH

        let config = SCStreamConfiguration()
        config.width = pixelW
        config.height = pixelH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        stream = s
        try await s.startCapture()
        print("Capture on display \(currentIndex): id=\(display.displayID) \(pixelW)x\(pixelH) @\(fps)fps")
    }

    func stop() {
        Task {
            try? await self.stream?.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let statusNumber = CMGetAttachment(
            sampleBuffer,
            key: SCStreamFrameInfo.status.rawValue as CFString,
            attachmentModeOut: nil
        ) as? NSNumber,
           let status = SCFrameStatus(rawValue: statusNumber.intValue) {
            guard status == .complete else { return }
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, time)
    }

    enum CaptureError: Error {
        case noDisplay
    }
}
