import Foundation
import CoreVideo
import CoreImage
import ImageIO
import CoreGraphics
import Metal

final class RegionEncoder {
    var onRegion: ((UInt32, UInt16, UInt16, UInt16, UInt16, Data) -> Void)?

    private let tileSize = 128
    private let jpegQuality: CGFloat = 0.35
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var prevPixelBuffer: CVPixelBuffer?
    private var width: Int = 0
    private var height: Int = 0
    private var forceFullFlag = true
    private var framesSinceRefresh = 0
    private let refreshInterval = 120
    private var frameId: UInt32 = 0
    private let lock = NSLock()

    func setup(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.width = width
        self.height = height
        prevPixelBuffer = nil
        forceFullFlag = true
        framesSinceRefresh = 0
    }

    func forceFullFrame() {
        lock.lock()
        forceFullFlag = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let w = width
        let h = height
        var force = forceFullFlag
        let prev = prevPixelBuffer
        forceFullFlag = false
        framesSinceRefresh += 1
        if framesSinceRefresh >= refreshInterval {
            framesSinceRefresh = 0
            force = true
        }
        lock.unlock()

        guard w > 0, h > 0 else { return }
        if prev == nil { force = true }

        frameId &+= 1
        let fid = frameId

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        var regionCount = 0
        var totalBytes = 0

        if force {
            let tilesWide = (w + tileSize - 1) / tileSize
            let tilesHigh = (h + tileSize - 1) / tileSize
            for ty in 0..<tilesHigh {
                for tx in 0..<tilesWide {
                    let rx = tx * tileSize
                    let ry = ty * tileSize
                    let rw = min(tileSize, w - rx)
                    let rh = min(tileSize, h - ry)
                    if let jpeg = encodeRegion(pixelBuffer, rx, ry, rw, rh, totalHeight: h) {
                        onRegion?(fid, UInt16(rx), UInt16(ry), UInt16(rw), UInt16(rh), jpeg)
                        regionCount += 1
                        totalBytes += jpeg.count
                    }
                }
            }
        } else {
            CVPixelBufferLockBaseAddress(prev!, .readOnly)
            let curBase = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let curStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let prevBase = CVPixelBufferGetBaseAddress(prev!)!
            let prevStride = CVPixelBufferGetBytesPerRow(prev!)

            let tilesWide = (w + tileSize - 1) / tileSize
            let tilesHigh = (h + tileSize - 1) / tileSize

            for ty in 0..<tilesHigh {
                for tx in 0..<tilesWide {
                    let rx = tx * tileSize
                    let ry = ty * tileSize
                    let rw = min(tileSize, w - rx)
                    let rh = min(tileSize, h - ry)

                    if isTileDirty(curBase, curStride, prevBase, prevStride, rx, ry, rw, rh) {
                        if let jpeg = encodeRegion(pixelBuffer, rx, ry, rw, rh, totalHeight: h) {
                            onRegion?(fid, UInt16(rx), UInt16(ry), UInt16(rw), UInt16(rh), jpeg)
                            regionCount += 1
                            totalBytes += jpeg.count
                        }
                    }
                }
            }

            CVPixelBufferUnlockBaseAddress(prev!, .readOnly)
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        lock.lock()
        prevPixelBuffer = pixelBuffer
        lock.unlock()
    }

    private func isTileDirty(_ curBase: UnsafeRawPointer, _ curStride: Int,
                             _ prevBase: UnsafeRawPointer, _ prevStride: Int,
                             _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        let curPtr = curBase.advanced(by: y * curStride + x * 4)
        let prevPtr = prevBase.advanced(by: y * prevStride + x * 4)
        let bytesPerRow = w * 4
        for row in stride(from: 0, to: h, by: 4) {
            if memcmp(curPtr.advanced(by: row * curStride),
                      prevPtr.advanced(by: row * prevStride),
                      bytesPerRow) != 0 {
                return true
            }
        }
        return false
    }

    private func encodeRegion(_ pixelBuffer: CVPixelBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, totalHeight: Int) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciY = totalHeight - y - h
        let rect = CGRect(x: x, y: ciY, width: w, height: h)
        guard let cgImage = ciContext.createCGImage(ciImage, from: rect) else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
