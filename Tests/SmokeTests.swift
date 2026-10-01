import Foundation
import CoreVideo

@main
struct SmokeTests {
    static func main() {
        testRoutes()
        testFragments()
        testRegions()
        print("PASS: routing, packet validation, fragment recovery, tile retry, idle refinement, pixel diff")
    }

    static func testRoutes() {
        var path = RelayPath()
        precondition(path.route(at: 0) == .tcp)
        path.acknowledge(direct: true, at: 10)
        path.acknowledge(direct: false, at: 12)
        precondition(path.route(at: 12) == .direct)
        precondition(path.route(at: 13) == .udp)
        precondition(path.route(at: 15) == .tcp)
        path = RelayPath()
        precondition(path.route(at: 15) == .tcp)
    }

    static func testFragments() {
        let assembler = UDPFragAssembler()
        let first = PacketHeader(type: .region, frameId: 1, fragIndex: 0, fragCount: 2, payloadLength: 1)
        let second = PacketHeader(type: .region, frameId: 1, fragIndex: 1, fragCount: 2, payloadLength: 1)
        precondition(PacketHeader.decode(first.encode()) == nil)
        var packet = first.encode()
        packet.append(1)
        precondition(PacketHeader.decode(packet) != nil)
        precondition(assembler.push(header: second, payload: Data([2]), now: 0) == nil)
        precondition(assembler.push(header: first, payload: Data([1]), now: 0) == Data([1, 2]))
        precondition(assembler.push(header: first, payload: Data([1]), now: 0) == nil)
        precondition(assembler.push(header: second, payload: Data([2]), now: 2) == nil)
        assembler.reset()
        precondition(assembler.push(header: second, payload: Data([2]), now: 2) == nil)
        var malformed = first
        malformed.fragIndex = 2
        precondition(assembler.push(header: malformed, payload: Data([1]), now: 2) == nil)
        malformed = first
        malformed.fragCount = 3
        precondition(assembler.push(header: malformed, payload: Data([1]), now: 2) == nil)
    }

    static func makeBuffer(changedOddRow: Bool = false) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128,
                                        kCVPixelFormatType_32BGRA, attributes, &result) == kCVReturnSuccess)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 255, stride * 128)
        if changedOddRow { memset(base.advanced(by: stride), 0, 4) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func testRegions() {
        let encoder = RegionEncoder(automaticRefresh: false)
        encoder.setup(width: 128, height: 128)
        let buffer = makeBuffer()
        var accept = false
        var images: [Data] = []
        var completed: [Int] = []
        encoder.onRegion = { _, _, _, _, _, image in
            if accept { images.append(image) }
            return accept
        }
        encoder.onFrameComplete = { _, count in completed.append(count) }
        encoder.encode(buffer, dirtyRects: nil, scaleFactor: 1, now: 10)
        precondition(images.isEmpty && completed.last == 0)
        accept = true
        encoder.refreshIdleFrame(now: 10.2)
        precondition(images.count == 1 && completed.last == 1)
        encoder.refreshIdleFrame(now: 10.5)
        precondition(images.count == 2 && completed.last == 1)
        precondition(images.last!.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        encoder.refreshIdleFrame(now: 10.6)
        precondition(images.count == 2 && completed.last == 0)
        encoder.encode(makeBuffer(changedOddRow: true), dirtyRects: nil, scaleFactor: 1, now: 10.7)
        precondition(images.count == 3 && completed.last == 1)
        encoder.setup(width: 128, height: 128)
        encoder.refreshIdleFrame(now: 11)
        precondition(images.count == 3)
    }
}