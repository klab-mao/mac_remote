import Foundation
import CoreVideo
import CoreImage
import ImageIO
import CoreGraphics
import Metal

final class RegionEncoder {
    var onRegion: ((UInt32, UInt16, UInt16, UInt16, UInt16, Data) -> Void)?
    var onFrameComplete: ((UInt32, Int) -> Void)?

    private let tileSize = 128
    private var currentQuality: CGFloat = 0.5
    private var qualityEMA: Double = -1
    private var webpSupported: Bool?
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
    private let refreshInterval = 60
    private var frameId: UInt32 = 0
    private let lock = NSLock()
    private var cursorX: Int = -1
    private var cursorY: Int = -1
    private let maxTilesPerFrame = 300

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

    func updateCursor(x: Int, y: Int) {
        lock.lock()
        cursorX = x
        cursorY = y
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, dirtyRects: [CGRect]?, scaleFactor: CGFloat) {
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

            var candidates: Set<Int>?
            if let rects = dirtyRects, !rects.isEmpty, scaleFactor > 0, fid % 30 != 0 {
                var keys = Set<Int>()
                let hh = CGFloat(h)
                for r0 in rects.prefix(16) {
                    let rp = CGRect(x: r0.minX * scaleFactor, y: r0.minY * scaleFactor,
                                    width: r0.width * scaleFactor, height: r0.height * scaleFactor)
                    let flipped = CGRect(x: rp.minX, y: hh - rp.maxY, width: rp.width, height: rp.height)
                    for rr in [rp, flipped] {
                        let inf = rr.insetBy(dx: -16, dy: -16)
                        let tx0 = max(0, Int(inf.minX) / tileSize)
                        let tx1 = min(tilesWide - 1, Int(inf.maxX) / tileSize)
                        let ty0 = max(0, Int(inf.minY) / tileSize)
                        let ty1 = min(tilesHigh - 1, Int(inf.maxY) / tileSize)
                        guard tx0 <= tx1, ty0 <= ty1 else { continue }
                        for ty in ty0...ty1 {
                            for tx in tx0...tx1 {
                                keys.insert((ty << 16) | tx)
                            }
                        }
                    }
                }
                if !keys.isEmpty { candidates = keys }
            }

            var dirtyTiles: [(tx: Int, ty: Int)] = []
            for ty in 0..<tilesHigh {
                for tx in 0..<tilesWide {
                    if let candidates, !candidates.contains((ty << 16) | tx) { continue }
                    let rx = tx * tileSize
                    let ry = ty * tileSize
                    let rw = min(tileSize, w - rx)
                    let rh = min(tileSize, h - ry)

                    if isTileDirty(curBase, curStride, prevBase, prevStride, rx, ry, rw, rh) {
                        dirtyTiles.append((tx, ty))
                    }
                }
            }

            let normalized = Double(dirtyTiles.count) / Double(max(tilesWide * tilesHigh, 1))
            qualityEMA = qualityEMA < 0 ? normalized : qualityEMA * 0.85 + normalized * 0.15
            let act = min(max(qualityEMA, 0), 1)
            currentQuality = CGFloat(0.7 - act * 0.5)

            if normalized > 0.7 {
                lock.lock()
                forceFullFlag = true
                lock.unlock()
            }

            let cx = cursorX
            let cy = cursorY
            let largeChange = normalized > 0.5
            if cx >= 0 && cy >= 0 && dirtyTiles.count > maxTilesPerFrame && !largeChange {
                dirtyTiles.sort { a, b in
                    let ax = a.tx * tileSize + tileSize / 2
                    let ay = a.ty * tileSize + tileSize / 2
                    let bx = b.tx * tileSize + tileSize / 2
                    let by = b.ty * tileSize + tileSize / 2
                    let da = (ax - cx) * (ax - cx) + (ay - cy) * (ay - cy)
                    let db = (bx - cx) * (bx - cx) + (by - cy) * (by - cy)
                    return da < db
                }
            }

            let limit = largeChange ? dirtyTiles.count : min(dirtyTiles.count, maxTilesPerFrame)
            for i in 0..<limit {
                let tx = dirtyTiles[i].tx
                let ty = dirtyTiles[i].ty
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

            CVPixelBufferUnlockBaseAddress(prev!, .readOnly)
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        lock.lock()
        prevPixelBuffer = pixelBuffer
        lock.unlock()

        onFrameComplete?(fid, regionCount)
    }

    private func isTileDirty(_ curBase: UnsafeRawPointer, _ curStride: Int,
                             _ prevBase: UnsafeRawPointer, _ prevStride: Int,
                             _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        let curPtr = curBase.advanced(by: y * curStride + x * 4)
        let prevPtr = prevBase.advanced(by: y * prevStride + x * 4)
        let bytesPerRow = w * 4
        for row in stride(from: 0, to: h, by: 2) {
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
        let quality = currentQuality
        if webpSupported != false {
            let webpData = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(webpData, "public.webp" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    webpSupported = true
                    return webpData as Data
                }
            }
            if webpSupported == nil {
                webpSupported = false
                print("[RegionEncoder] WebP encode unavailable — falling back to JPEG")
            }
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
