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
    private let fullLayer = CALayer()

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
        needsLayout = true
    }

    func updateRegion(x: Int, y: Int, jpegData: Data) {
        updateRegionBatch(regions: [(x, y, jpegData)])
    }

    func updateRegionBatch(regions: [(x: Int, y: Int, jpegData: Data)]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var decoded: [(x: Int, y: Int, cgImage: CGImage)] = []
            for (x, y, jpegData) in regions {
                guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                decoded.append((x, y, cgImage))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.remoteSize.width > 0, self.remoteSize.height > 0 else { return }
                CATransaction.begin()
                CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
                for (x, y, cgImage) in decoded {
                    let w = cgImage.width
                    let h = cgImage.height
                    if x == 0 && y == 0 && w == Int(self.remoteSize.width) && h == Int(self.remoteSize.height) {
                        self.fullLayer.contents = cgImage
                        print("[RegionView] full-screen JPEG received: \(w)x\(h)")
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
