import Foundation
import CoreVideo
import CoreImage
import ImageIO
import CoreGraphics
import Metal

final class RegionEncoder {
    var onRegion: ((UInt32, UInt16, UInt16, UInt16, UInt16, Data) -> Bool)?
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
    private var lastRefresh: TimeInterval = 0
    private var pendingTiles = Set<Int>()
    private var refinementDeadlines: [Int: TimeInterval] = [:]
    private var nextTile = 0
    private var frameId: UInt32 = 0
    private let lock = NSLock()
    private var cursorX: Int = -1
    private var cursorY: Int = -1
    private let maxTilesPerFrame = 300
    private var refreshTimer: DispatchSourceTimer?
    private var lastCapture: TimeInterval = 0

    init(automaticRefresh: Bool = true) {
        if automaticRefresh {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mac_remote.refinement"))
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.refreshIdleFrame() }
            timer.resume()
            refreshTimer = timer
        }
    }

    deinit { refreshTimer?.cancel() }

    func setup(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.width = width
        self.height = height
        prevPixelBuffer = nil
        forceFullFlag = true
        lastRefresh = 0
        pendingTiles.removeAll()
        refinementDeadlines.removeAll()
        nextTile = 0
        qualityEMA = -1
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

    func encode(_ pixelBuffer: CVPixelBuffer, dirtyRects: [CGRect]?, scaleFactor: CGFloat, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        lastCapture = now
        encodeLocked(pixelBuffer, now: now)
    }

    func refreshIdleFrame(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastCapture >= 0.1, let pixelBuffer = prevPixelBuffer else { return }
        encodeLocked(pixelBuffer, now: now)
    }

    private func encodeLocked(_ pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        let w = width
        let h = height
        let force = forceFullFlag || now - lastRefresh >= 5
        let prev = prevPixelBuffer
        forceFullFlag = false
        if force { lastRefresh = now }
        guard w > 0, h > 0,
              CVPixelBufferGetWidth(pixelBuffer) == w,
              CVPixelBufferGetHeight(pixelBuffer) == h else { return }

        frameId &+= 1
        let fid = frameId
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        if let prev { CVPixelBufferLockBaseAddress(prev, .readOnly) }
        defer { if let prev { CVPixelBufferUnlockBaseAddress(prev, .readOnly) } }
        guard let curBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let curStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let prevBase = prev.flatMap { CVPixelBufferGetBaseAddress($0) }
        let prevStride = prev.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let tilesWide = (w + tileSize - 1) / tileSize
        let tilesHigh = (h + tileSize - 1) / tileSize
        let tileCount = tilesWide * tilesHigh
        var changedCount = 0

        for key in 0..<tileCount {
            let rx = (key % tilesWide) * tileSize
            let ry = (key / tilesWide) * tileSize
            let rw = min(tileSize, w - rx)
            let rh = min(tileSize, h - ry)
            let changed = prevBase.map { isTileDirty(curBase, curStride, $0, prevStride, rx, ry, rw, rh) } ?? true
            if changed {
                changedCount += 1
                pendingTiles.insert(key)
                refinementDeadlines[key] = now + 0.3
            } else if force || (refinementDeadlines[key].map { now >= $0 } ?? false) {
                pendingTiles.insert(key)
            }
        }
        let activity = Double(changedCount) / Double(tileCount)
        qualityEMA = qualityEMA < 0 ? activity : qualityEMA * 0.85 + activity * 0.15
        currentQuality = CGFloat(0.7 - min(max(qualityEMA, 0), 1) * 0.5)
        var regionCount = 0
        let startTile = nextTile
        for offset in 0..<tileCount {
            let key = (startTile + offset) % tileCount
            guard pendingTiles.contains(key) else { continue }
            let rx = (key % tilesWide) * tileSize
            let ry = (key / tilesWide) * tileSize
            let rw = min(tileSize, w - rx)
            let rh = min(tileSize, h - ry)
            let lossless = refinementDeadlines[key].map { now >= $0 } ?? true
            guard let image = encodeRegion(pixelBuffer, rx, ry, rw, rh, totalHeight: h, lossless: lossless) else { continue }
            guard onRegion?(fid, UInt16(rx), UInt16(ry), UInt16(rw), UInt16(rh), image) == true else { break }
            pendingTiles.remove(key)
            if lossless { refinementDeadlines.removeValue(forKey: key) }
            nextTile = (key + 1) % tileCount
            regionCount += 1
            if regionCount >= maxTilesPerFrame { break }
        }
        prevPixelBuffer = pixelBuffer
        onFrameComplete?(fid, regionCount)
    }

    private func isTileDirty(_ curBase: UnsafeRawPointer, _ curStride: Int,
                             _ prevBase: UnsafeRawPointer, _ prevStride: Int,
                             _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        let curPtr = curBase.advanced(by: y * curStride + x * 4)
        let prevPtr = prevBase.advanced(by: y * prevStride + x * 4)
        let bytesPerRow = w * 4
        for row in 0..<h {
            if memcmp(curPtr.advanced(by: row * curStride),
                      prevPtr.advanced(by: row * prevStride),
                      bytesPerRow) != 0 {
                return true
            }
        }
        return false
    }

    private func encodeRegion(_ pixelBuffer: CVPixelBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, totalHeight: Int, lossless: Bool) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciY = totalHeight - y - h
        let rect = CGRect(x: x, y: ciY, width: w, height: h)
        guard let cgImage = ciContext.createCGImage(ciImage, from: rect) else { return nil }
        if lossless {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
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
