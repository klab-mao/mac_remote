import AppKit
import CoreGraphics
import ImageIO
import Foundation

protocol RemoteScreenView: AnyObject {
    var remoteSize: CGSize { get set }
    func normalizedPoint(for event: NSEvent) -> (nx: Float, ny: Float)?
    func showStatus(_ text: String, hideAfter: TimeInterval?)
    func showDisplayInfo(current: Int, total: Int)
    var nsView: NSView { get }
}

final class RegionView: NSView {
    private let rootLayer = CALayer()
    private let screenLayer = CALayer()
    private let infoLabel = NSTextField(labelWithString: "")
    private var infoHideTimer: Timer?
    private var tileLayers: [Int: CALayer] = [:]
    private var tileLatestFrame: [Int: UInt32] = [:]
    private let fullLayer = CALayer()
    private var frameBuffers: [UInt32: [(x: Int, y: Int, cgImage: CGImage)]] = [:]
    private var expectedTileCounts: [UInt32: Int] = [:]
    private var flushTimer: Timer?
    private var latestRenderedFrameId: UInt32 = 0
    private let caretLayer = CALayer()
    private var caretBlinkTimer: Timer?
    private var caretVisible = false

    var remoteSize: CGSize = .zero {
        didSet {
            guard remoteSize != oldValue else { return }
            updateScreenLayerFrame()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = rootLayer
        rootLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        screenLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        rootLayer.addSublayer(screenLayer)

        fullLayer.contentsGravity = .resize
        screenLayer.addSublayer(fullLayer)

        infoLabel.alignment = .center
        infoLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        infoLabel.textColor = .white
        infoLabel.isBezeled = false
        infoLabel.wantsLayer = true
        infoLabel.layer?.cornerRadius = 10
        infoLabel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        infoLabel.isHidden = true
        addSubview(infoLabel)

        caretLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        caretLayer.isHidden = true
        screenLayer.addSublayer(caretLayer)

        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.flushPendingTiles()
        }
    }

    func updateCaret(visible: Bool, nx: Float, ny: Float, height: UInt16) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.caretVisible = visible
            if visible {
                let x = CGFloat(nx) * self.remoteSize.width
                let flippedY = self.remoteSize.height - CGFloat(ny) * self.remoteSize.height - CGFloat(height)
                self.caretLayer.frame = CGRect(x: x, y: flippedY, width: 2, height: CGFloat(height))
                self.caretLayer.isHidden = false
                if self.caretBlinkTimer == nil {
                    self.startCaretBlink()
                }
            } else {
                self.caretLayer.isHidden = true
                self.caretBlinkTimer?.invalidate()
                self.caretBlinkTimer = nil
            }
        }
    }

    private func startCaretBlink() {
        caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.caretVisible {
                self.caretLayer.isHidden.toggle()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func tileKey(x: Int, y: Int) -> Int {
        (y << 16) | x
    }

    private func updateScreenLayerFrame() {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return }
        fullLayer.frame = CGRect(origin: .zero, size: remoteSize)
        for (_, tl) in tileLayers {
            tl.removeFromSuperlayer()
        }
        tileLayers.removeAll()
        tileLatestFrame.removeAll()
        needsLayout = true
    }

    func updateRegion(x: Int, y: Int, jpegData: Data) {
        updateRegionBatch(regions: [(x, y, 0, jpegData)])
    }

    func updateRegionBatch(regions: [(x: Int, y: Int, frameId: UInt32, jpegData: Data)]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var decoded: [(x: Int, y: Int, frameId: UInt32, cgImage: CGImage)] = []
            for (x, y, frameId, jpegData) in regions {
                guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                decoded.append((x, y, frameId, cgImage))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var immediateTiles: [(x: Int, y: Int, cgImage: CGImage)] = []
                for (x, y, fid, cgImage) in decoded {
                    let key = self.tileKey(x: x, y: y)
                    if let existing = self.tileLatestFrame[key], existing > fid {
                        continue
                    }
                    if fid <= self.latestRenderedFrameId {
                        immediateTiles.append((x, y, cgImage))
                        self.tileLatestFrame[key] = fid
                    } else {
                        self.frameBuffers[fid, default: []].append((x, y, cgImage))
                    }
                }
                if !immediateTiles.isEmpty {
                    self.renderTiles(immediateTiles)
                }
            }
        }
    }

    func frameComplete(frameId: UInt32, expectedTiles: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.renderFrame(frameId)
        }
    }

    private func renderFrame(_ frameId: UInt32) {
        guard let tiles = frameBuffers.removeValue(forKey: frameId), !tiles.isEmpty else { return }
        expectedTileCounts.removeValue(forKey: frameId)
        var freshTiles: [(x: Int, y: Int, cgImage: CGImage)] = []
        for (x, y, cgImage) in tiles {
            let key = tileKey(x: x, y: y)
            if let existing = tileLatestFrame[key], existing > frameId {
                continue
            }
            freshTiles.append((x, y, cgImage))
            tileLatestFrame[key] = frameId
        }
        if !freshTiles.isEmpty {
            renderTiles(freshTiles)
        }
        latestRenderedFrameId = max(latestRenderedFrameId, frameId)
    }

    private func renderTiles(_ tiles: [(x: Int, y: Int, cgImage: CGImage)]) {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        for (x, y, cgImage) in tiles {
            let w = cgImage.width
            let h = cgImage.height
            if x == 0 && y == 0 && w == Int(self.remoteSize.width) && h == Int(self.remoteSize.height) {
                self.fullLayer.contents = cgImage
                continue
            }
            let key = self.tileKey(x: x, y: y)
            let tileLayer: CALayer
            if let existing = self.tileLayers[key] {
                tileLayer = existing
            } else {
                tileLayer = CALayer()
                tileLayer.contentsGravity = .resize
                let flippedY = Int(self.remoteSize.height) - y - h
                tileLayer.frame = CGRect(x: x, y: flippedY, width: w, height: h)
                self.screenLayer.addSublayer(tileLayer)
                self.tileLayers[key] = tileLayer
            }
            tileLayer.contents = cgImage
        }
        CATransaction.commit()
    }

    private func flushPendingTiles() {
        if let maxFid = frameBuffers.keys.max(), maxFid > latestRenderedFrameId {
            renderFrame(maxFid)
        }
    }

    override func layout() {
        super.layout()
        let vw = bounds.width
        let vh = bounds.height
        if remoteSize.width > 0, remoteSize.height > 0, vw > 0, vh > 0 {
            let scale = min(vw / remoteSize.width, vh / remoteSize.height)
            let dw = remoteSize.width * scale
            let dh = remoteSize.height * scale
            let offX = (vw - dw) / 2
            let offY = (vh - dh) / 2
            screenLayer.bounds = CGRect(origin: .zero, size: remoteSize)
            screenLayer.position = CGPoint(x: offX + dw / 2, y: offY + dh / 2)
            screenLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        infoLabel.sizeToFit()
        let labelSize = infoLabel.fittingSize
        infoLabel.frame = NSRect(
            x: (bounds.width - labelSize.width) / 2,
            y: (bounds.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    func showDisplayInfo(current: Int, total: Int) {
        showStatus("Display \(current + 1) / \(total)")
    }

    func showStatus(_ text: String, hideAfter: TimeInterval? = 2.5) {
        infoLabel.stringValue = text
        infoLabel.sizeToFit()
        needsLayout = true
        infoLabel.isHidden = false
        infoHideTimer?.invalidate()
        if let hideAfter {
            infoHideTimer = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { [weak self] _ in
                self?.infoLabel.isHidden = true
            }
        }
    }

    func normalizedPoint(for event: NSEvent) -> (nx: Float, ny: Float)? {
        let local = convert(event.locationInWindow, from: nil)
        var vw = bounds.width
        var vh = bounds.height
        if vw <= 0 || vh <= 0, let win = window {
            vw = win.contentView?.frame.width ?? 0
            vh = win.contentView?.frame.height ?? 0
        }
        guard vw > 0, vh > 0, remoteSize.width > 0, remoteSize.height > 0 else {
            return nil
        }
        let scale = min(vw / remoteSize.width, vh / remoteSize.height)
        let dw = remoteSize.width * scale
        let dh = remoteSize.height * scale
        let offX = (vw - dw) / 2
        let offY = (vh - dh) / 2
        let nx = (local.x - offX) / dw
        let nyTopLeft = 1.0 - (local.y - offY) / dh
        return (Float(min(max(nx, 0), 1)), Float(min(max(nyTopLeft, 0), 1)))
    }

    override var acceptsFirstResponder: Bool { true }
}

extension RegionView: RemoteScreenView {
    var nsView: NSView { self }
}
