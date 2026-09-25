import Foundation

public enum PacketType: UInt8 {
    case video = 0
    case input = 1
    case control = 2
}

public enum ControlSubType: UInt8 {
    case hello = 0
    case helloAck = 1
    case params = 2
    case keyframeRequest = 3
    case switchDisplay = 4
    case displayInfo = 5
}

public enum InputKind: UInt8 {
    case mouseMove = 0
    case mouseDown = 1
    case mouseUp = 2
    case scroll = 3
    case keyDown = 4
    case keyUp = 5
    case flagsChanged = 6
}

public struct PacketHeader {
    public static let size = 16
    public static let version: UInt8 = 1

    public var type: PacketType
    public var flags: UInt8
    public var frameId: UInt32
    public var fragIndex: UInt16
    public var fragCount: UInt16
    public var payloadLength: UInt32

    public init(type: PacketType, flags: UInt8 = 0, frameId: UInt32 = 0, fragIndex: UInt16 = 0, fragCount: UInt16 = 1, payloadLength: UInt32 = 0) {
        self.type = type
        self.flags = flags
        self.frameId = frameId
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.payloadLength = payloadLength
    }

    public func encode() -> Data {
        var d = Data(capacity: PacketHeader.size)
        d.append(PacketHeader.version)
        d.append(type.rawValue)
        d.append(flags)
        d.append(0)
        d.appendLE(frameId)
        d.appendLE(fragIndex)
        d.appendLE(fragCount)
        d.appendLE(payloadLength)
        return d
    }

    public static func decode(_ data: Data) -> PacketHeader? {
        guard data.count >= PacketHeader.size else { return nil }
        let b = [UInt8](data.prefix(PacketHeader.size))
        guard b[0] == PacketHeader.version else { return nil }
        guard let type = PacketType(rawValue: b[1]) else { return nil }
        let flags = b[2]
        let frameId = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        let fragIndex = UInt16(b[8]) | UInt16(b[9]) << 8
        let fragCount = UInt16(b[10]) | UInt16(b[11]) << 8
        let payloadLength = UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
        return PacketHeader(type: type, flags: flags, frameId: frameId, fragIndex: fragIndex, fragCount: fragCount, payloadLength: payloadLength)
    }
}

public struct InputPacket {
    public var kind: InputKind
    public var button: UInt8
    public var keyCode: UInt16
    public var flags: UInt32
    public var nx: Float
    public var ny: Float
    public var dx: Float
    public var dy: Float
    public var clickCount: UInt32

    public static let size = 28

    public init(kind: InputKind, button: UInt8 = 0, keyCode: UInt16 = 0, flags: UInt32 = 0, nx: Float = 0, ny: Float = 0, dx: Float = 0, dy: Float = 0, clickCount: UInt32 = 0) {
        self.kind = kind
        self.button = button
        self.keyCode = keyCode
        self.flags = flags
        self.nx = nx
        self.ny = ny
        self.dx = dx
        self.dy = dy
        self.clickCount = clickCount
    }

    public func encode() -> Data {
        var d = Data(capacity: InputPacket.size)
        d.append(kind.rawValue)
        d.append(button)
        d.appendLE(keyCode)
        d.appendLE(flags)
        d.appendLE(nx)
        d.appendLE(ny)
        d.appendLE(dx)
        d.appendLE(dy)
        d.appendLE(clickCount)
        return d
    }

    public static func decode(_ data: Data) -> InputPacket? {
        guard data.count >= InputPacket.size else { return nil }
        let b = [UInt8](data.prefix(InputPacket.size))
        guard let kind = InputKind(rawValue: b[0]) else { return nil }
        let button = b[1]
        let keyCode = UInt16(b[2]) | UInt16(b[3]) << 8
        let flags = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        let nx = Float(bitPattern: UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10]) << 16 | UInt32(b[11]) << 24)
        let ny = Float(bitPattern: UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24)
        let dx = Float(bitPattern: UInt32(b[16]) | UInt32(b[17]) << 8 | UInt32(b[18]) << 16 | UInt32(b[19]) << 24)
        let dy = Float(bitPattern: UInt32(b[20]) | UInt32(b[21]) << 8 | UInt32(b[22]) << 16 | UInt32(b[23]) << 24)
        let clickCount = UInt32(b[24]) | UInt32(b[25]) << 8 | UInt32(b[26]) << 16 | UInt32(b[27]) << 24
        return InputPacket(kind: kind, button: button, keyCode: keyCode, flags: flags, nx: nx, ny: ny, dx: dx, dy: dy, clickCount: clickCount)
    }
}

public enum Packetizer {
    public static let maxPayloadSize = 1300

    public static func fragment(_ payload: Data, frameId: UInt32, isKeyframe: Bool) -> [Data] {
        let bytes = [UInt8](payload)
        let count = max(1, (bytes.count + maxPayloadSize - 1) / maxPayloadSize)
        var datagrams: [Data] = []
        datagrams.reserveCapacity(count)
        for i in 0..<count {
            let start = i * maxPayloadSize
            let end = min(start + maxPayloadSize, bytes.count)
            let chunk = bytes[start..<end]
            let header = PacketHeader(
                type: .video,
                flags: isKeyframe ? 1 : 0,
                frameId: frameId,
                fragIndex: UInt16(i),
                fragCount: UInt16(count),
                payloadLength: UInt32(chunk.count)
            )
            var d = header.encode()
            d.append(contentsOf: chunk)
            datagrams.append(d)
        }
        return datagrams
    }

    public static func controlPacket(_ subType: ControlSubType, extra: Data = Data()) -> Data {
        let header = PacketHeader(type: .control, frameId: 0, fragIndex: 0, fragCount: 1, payloadLength: UInt32(1 + extra.count))
        var d = header.encode()
        d.append(subType.rawValue)
        d.append(extra)
        return d
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xff))
        append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
    }

    mutating func appendLE(_ v: Float) {
        Swift.withUnsafeBytes(of: v.bitPattern.littleEndian) { append(contentsOf: $0) }
    }
}