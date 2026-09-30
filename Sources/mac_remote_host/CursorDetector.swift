import AppKit
import CoreGraphics
import MacRemoteCore

enum CursorDetector {
    private struct CursorSignature: Hashable {
        let pixelHash: UInt64
        let hotX: Int
        let hotY: Int
    }

    private static let standardCursors: [(CursorType, NSCursor)] = [
        (.arrow, NSCursor.arrow),
        (.iBeam, NSCursor.iBeam),
        (.crosshair, NSCursor.crosshair),
        (.openHand, NSCursor.openHand),
        (.closedHand, NSCursor.closedHand),
        (.pointingHand, NSCursor.pointingHand),
        (.resizeLeft, NSCursor.resizeLeft),
        (.resizeRight, NSCursor.resizeRight),
        (.resizeLeftRight, NSCursor.resizeLeftRight),
        (.resizeUp, NSCursor.resizeUp),
        (.resizeDown, NSCursor.resizeDown),
        (.resizeUpDown, NSCursor.resizeUpDown),
        (.disappearingItem, NSCursor.disappearingItem),
        (.contextualMenu, NSCursor.contextualMenu),
    ]

    private static let normalizedSize = 24

    private static func renderSignature(for cursor: NSCursor) -> CursorSignature? {
        let sz = normalizedSize
        let bytesPerRow = sz * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * sz)

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixelData,
                                   width: sz, height: sz,
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        var rect = CGRect(x: 0, y: 0, width: cursor.image.size.width, height: cursor.image.size.height)
        guard let cgImage = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sz, height: sz))

        var hash: UInt64 = 14695981039346656037
        for byte in pixelData {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }

        return CursorSignature(pixelHash: hash,
                               hotX: Int(cursor.hotSpot.x),
                               hotY: Int(cursor.hotSpot.y))
    }

    private static let cachedSignatures: [CursorSignature: CursorType] = {
        var dict: [CursorSignature: CursorType] = [:]
        for (type, cursor) in standardCursors {
            if let sig = renderSignature(for: cursor) {
                dict[sig] = type
            }
        }
        return dict
    }()

    private static let cachedTIFFs: [CursorType: Data] = {
        var dict: [CursorType: Data] = [:]
        for (type, cursor) in standardCursors {
            if let tiff = cursor.image.tiffRepresentation {
                dict[type] = tiff
            }
        }
        return dict
    }()

    static func detect(_ cursor: NSCursor) -> CursorType {
        if let sig = renderSignature(for: cursor), let type = cachedSignatures[sig] {
            return type
        }
        if let tiff = cursor.image.tiffRepresentation {
            for (type, cached) in cachedTIFFs {
                if tiff == cached {
                    return type
                }
            }
        }
        return classifyByHeuristic(cursor)
    }

    private static func classifyByHeuristic(_ cursor: NSCursor) -> CursorType {
        let sz = cursor.image.size
        let w = sz.width
        let h = sz.height
        let hs = cursor.hotSpot
        let cx = w / 2
        let cy = h / 2
        let centered = abs(hs.x - cx) < 4 && abs(hs.y - cy) < 4
        guard centered, w >= 16, h >= 16, w <= 40, h <= 40 else { return .custom }
        if w > h * 1.15 {
            return .resizeLeftRight
        }
        if h > w * 1.15 {
            return .resizeUpDown
        }
        return .resizeDiagonal
    }
}
