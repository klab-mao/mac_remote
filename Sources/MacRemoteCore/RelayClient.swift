import Foundation
import Network
import CryptoKit
import Darwin

public enum RelayRole {
    case host(deviceId: String)
    case viewer(username: String, deviceId: String)
}

enum CtrlFrameType: UInt16 {
    case challenge = 1
    case authHost = 2
    case authUser = 3
    case ok = 4
    case err = 5
    case connectReq = 6
    case sessionInfo = 7
    case ping = 8
    case pong = 9
    case data = 10
}

enum CtrlCodec {
    static let headerSize = 6

    static func frame(_ type: CtrlFrameType, _ payload: Data) -> Data {
        var d = Data(capacity: headerSize + payload.count)
        d.appendLE(type.rawValue)
        d.appendLE(UInt32(payload.count))
        d.append(payload)
        return d
    }

    static func authPayload(name: String, nonce: Data, password: String) -> Data {
        var d = Data()
        let nameBytes = Array(name.utf8)
        d.append(UInt8(nameBytes.count))
        d.append(contentsOf: nameBytes)
        let key = SHA256.hash(data: Data(password.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: key))
        d.append(contentsOf: mac)
        return d
    }

    static func namePayload(_ name: String) -> Data {
        var d = Data()
        let bytes = Array(name.utf8)
        d.append(UInt8(bytes.count))
        d.append(contentsOf: bytes)
        return d
    }
}

public enum SecureInput {
    public static func readPassword(prompt: String) -> String {
        print(prompt, terminator: "")
        fflush(stdout)
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var masked = original
        masked.c_lflag &= ~tcflag_t(UInt32(ECHO))
        tcsetattr(STDIN_FILENO, TCSANOW, &masked)
        let line = readLine() ?? ""
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        print("")
        return line
    }
}

// BSD socket UDP — can send to any endpoint, used for relay + hole punching.
final class RawUDPSocket {
    private var fd: Int32 = -1
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var recvBuf = [UInt8](repeating: 0, count: 65536)

    var onDatagram: ((Data) -> Void)?
    var onState: ((String) -> Void)?
    private(set) var localPort: UInt16 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            onState?("socket creation failed")
            return
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                bind(fd, saddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            onState?("bind failed")
            Darwin.close(fd); fd = -1
            return
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                _ = getsockname(fd, saddr, &boundLen)
            }
        }
        localPort = UInt16(bigEndian: boundAddr.sin_port)

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.doReceive()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { Darwin.close(self.fd); self.fd = -1 }
        }
        src.resume()
        source = src
        onState?("ready (local port \(localPort))")
    }

    private func doReceive() {
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                recvfrom(fd, &recvBuf, recvBuf.count, 0, saddr, &addrLen)
            }
        }
        if n > 0 {
            onDatagram?(Data(recvBuf[0..<Int(n)]))
        }
    }

    func sendTo(_ data: Data, host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let sin = self.resolve(host: host, port: port) else {
                self.onState?("resolve failed: \(host)")
                return
            }
            data.withUnsafeBytes { ptr in
                withUnsafePointer(to: sin) { sinPtr in
                    sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                        var retries = 0
                        var sent = false
                        while retries < 20 {
                            let result = sendto(self.fd, ptr.baseAddress, data.count, 0,
                                               saddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                            if result >= 0 { sent = true; break }
                            if errno != EAGAIN && errno != ENOBUFS {
                                break
                            }
                            usleep(500)
                            retries += 1
                        }
                    }
                }
            }
        }
    }

    private func resolve(host: String, port: UInt16) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        guard let aiAddr = first.pointee.ai_addr else { return nil }
        return aiAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    func close() {
        source?.cancel()
        source = nil
    }
}

public final class RelayTransport: Transport {
    public var onPacket: ((PacketHeader, Data) -> Void)?
    public var onState: ((String) -> Void)?

    private let relayHost: String
    private let controlPort: UInt16
    private let role: RelayRole
    private let secret: String

    private let queue = DispatchQueue(label: "mac_remote.relay")
    private var control: NWConnection?
    private var dataSocket: RawUDPSocket?
    private var buffer = Data()
    private var nonce = Data()
    private var phase: Phase = .disconnected
    private var sessionId: UInt64 = 0
    private var relayUdpPort: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?
    private var lastPongTime: Date = .distantFuture

    // Hole punching state
    private var peerHost: String?
    private var peerPort: UInt16 = 0
    private var directMode = false
    private var punchTimer: DispatchSourceTimer?
    private var punchAttempts = 0
    private var bindTimer: DispatchSourceTimer?
    private var bindPacket = Data()
    private var reconnecting = false

    private enum Phase {
        case disconnected
        case awaitingChallenge
        case awaitingAuthResult
        case awaitingSession
        case established
    }

    public init(host: String, controlPort: UInt16, role: RelayRole, secret: String) {
        self.relayHost = host
        self.controlPort = controlPort
        self.role = role
        self.secret = secret
    }

    public func start() {
        phase = .awaitingChallenge
        let conn = NWConnection(
            host: NWEndpoint.Host(relayHost),
            port: NWEndpoint.Port(rawValue: controlPort)!,
            using: .tcp
        )
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("relay control connected")
            case .failed(let error):
                self?.onState?("relay control failed: \(error)")
                self?.reconnect()
            case .waiting(let error):
                self?.onState?("relay control waiting: \(error)")
            default:
                break
            }
        }
        control = conn
        conn.start(queue: queue)
        scheduleControlReceive()
        startPingTimer()
    }

    public func reconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        phase = .disconnected
        buffer = Data()
        pingTimer?.cancel(); pingTimer = nil
        bindTimer?.cancel(); bindTimer = nil
        punchTimer?.cancel(); punchTimer = nil
        control?.cancel()
        dataSocket = nil
        onState?("relay reconnecting in 3s...")
        queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self else { return }
            self.reconnecting = false
            self.start()
        }
    }

    private func startPingTimer() {
        lastPongTime = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendCtrl(.ping, Data())
            let elapsed = Date().timeIntervalSince(self.lastPongTime)
            if elapsed > 20 {
                self.onState?("relay pong timeout (\(Int(elapsed))s) — forcing reconnect")
                self.reconnect()
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func scheduleControlReceive() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.onState?("relay control closed (\(error?.localizedDescription ?? "EOF"))")
                self.reconnect()
                return
            }
            self.scheduleControlReceive()
        }
    }

    private func processBuffer() {
        while buffer.count >= CtrlCodec.headerSize {
            let typeRaw = UInt16(buffer[buffer.startIndex]) | UInt16(buffer[buffer.startIndex + 1]) << 8
            let len = UInt32(buffer[buffer.startIndex + 2]) | UInt32(buffer[buffer.startIndex + 3]) << 8
                | UInt32(buffer[buffer.startIndex + 4]) << 16 | UInt32(buffer[buffer.startIndex + 5]) << 24
            let total = CtrlCodec.headerSize + Int(len)
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: (buffer.startIndex + CtrlCodec.headerSize)..<(buffer.startIndex + total))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
            guard let type = CtrlFrameType(rawValue: typeRaw) else {
                continue
            }
            handleCtrl(type, payload)
        }
    }

    private func handleCtrl(_ type: CtrlFrameType, _ payload: Data) {
        switch type {
        case .challenge:
            nonce = payload
            sendAuth()
        case .ok:
            if phase == .awaitingAuthResult {
                phase = .awaitingSession
                if case .viewer(_, let deviceId) = role {
                    sendCtrl(.connectReq, CtrlCodec.namePayload(deviceId))
                }
            }
        case .err:
            let msgLen = payload.first.map { Int($0) } ?? 0
            let msg = msgLen > 0 && payload.count >= 1 + msgLen
                ? String(data: payload.subdata(in: 1..<(1 + msgLen)), encoding: .utf8) ?? "unknown"
                : "unknown"
            onState?("relay rejected: \(msg)")
            phase = .disconnected
        case .sessionInfo:
            guard payload.count >= 10 else { return }
            sessionId = readLE64(payload, 0)
            let udpPort = UInt16(payload[8]) | UInt16(payload[9]) << 8
            setupDataPlane(sessionId: sessionId, udpPort: udpPort)
        case .pong:
            lastPongTime = Date()
        case .data:
            if let header = PacketHeader.decode(payload) {
                let packetPayload = payload.subdata(in: PacketHeader.size..<payload.count)
                onPacket?(header, packetPayload)
            } else {
                print("[relay] data decode failed: \(payload.count) bytes")
            }
        default:
            break
        }
    }

    private func sendAuth() {
        phase = .awaitingAuthResult
        switch role {
        case .host(let deviceId):
            sendCtrl(.authHost, CtrlCodec.authPayload(name: deviceId, nonce: nonce, password: secret))
        case .viewer(let username, _):
            sendCtrl(.authUser, CtrlCodec.authPayload(name: username, nonce: nonce, password: secret))
        }
    }

    private func setupDataPlane(sessionId: UInt64, udpPort: UInt16) {
        self.relayUdpPort = udpPort

        let sock = RawUDPSocket(queue: queue)
        sock.onDatagram = { [weak self] data in
            self?.handleDataDatagram(data)
        }
        sock.onState = { [weak self] state in
            self?.onState?("relay data: \(state)")
        }
        sock.start()
        dataSocket = sock

        bindPacket = Data()
        bindPacket.append(contentsOf: Array("RMBD".utf8))
        bindPacket.appendLE(sessionId)
        let side: UInt8
        if case .host = role { side = 1 } else { side = 2 }
        bindPacket.append(side)
        sock.sendTo(bindPacket, host: relayHost, port: udpPort)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dataSocket?.sendTo(self.bindPacket, host: self.relayHost, port: self.relayUdpPort)
        }
        timer.resume()
        bindTimer = timer

        phase = .established
        onState?("relay session \(sessionId) ready (udp \(udpPort))")
    }

    // MARK: - Data datagram handling (RPEP, PUNCH, or mac_remote packet)

    private let fragAssembler = UDPFragAssembler()

    private func handleDataDatagram(_ data: Data) {
        // Keep bind timer running to refresh NAT mapping and relay address record
        // RPEP: peer endpoint info from relay
        if data.count >= 7, data[0..<4] == Data([0x52, 0x50, 0x45, 0x50]) {
            parsePeerEndpoint(data)
            return
        }
        // PUNCH: hole-punch probe from peer
        if data.count >= 13, data[0..<5] == Data([0x50, 0x55, 0x4E, 0x43, 0x48]) {
            onPunchReceived()
            return
        }
        // Otherwise: mac_remote packet (from relay or peer)
        if let header = PacketHeader.decode(data) {
            let payload = data.subdata(in: PacketHeader.size..<data.count)
            if header.fragCount > 1 {
                if let complete = fragAssembler.push(header: header, payload: payload) {
                    let completeHeader = PacketHeader(type: header.type, flags: header.flags, frameId: header.frameId, fragIndex: 0, fragCount: 1, payloadLength: UInt32(complete.count))
                    onPacket?(completeHeader, complete)
                }
            } else {
                onPacket?(header, payload)
            }
        }
    }

    // MARK: - Hole punching

    private func parsePeerEndpoint(_ data: Data) {
        // Format: "RPEP" (4B) + [u8 ipLen] [ip bytes] [u16 port LE]
        guard data.count >= 7 else { return }
        let ipLen = Int(data[4])
        guard data.count >= 5 + ipLen + 2 else { return }
        let ip = String(data: data.subdata(in: 5..<(5 + ipLen)), encoding: .utf8) ?? ""
        let port = UInt16(data[5 + ipLen]) | UInt16(data[5 + ipLen + 1]) << 8

        if peerHost == ip && peerPort == port { return }
        peerHost = ip
        peerPort = port
        onState?("peer endpoint: \(ip):\(port) — starting hole punch")
        startHolePunch()
    }

    private func startHolePunch() {
        guard let host = peerHost else { return }
        if punchTimer != nil { return }
        punchAttempts = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.punchAttempts += 1
            if self.punchAttempts > 15 {
                self.punchTimer?.cancel()
                self.punchTimer = nil
                if !self.directMode {
                    self.onState?("hole punch failed — staying on relay")
                }
                return
            }
            var punch = Data()
            punch.append(contentsOf: Array("PUNCH".utf8))
            punch.appendLE(self.sessionId)
            self.dataSocket?.sendTo(punch, host: host, port: self.peerPort)
        }
        timer.resume()
        punchTimer = timer
    }

    private func onPunchReceived() {
        if !directMode {
            directMode = true
            punchTimer?.cancel()
            punchTimer = nil
            onState?("hole punch success — switched to direct mode (peer \(peerHost ?? "?"):\(peerPort))")
        }
    }

    // MARK: - Sending

    private func sendCtrl(_ type: CtrlFrameType, _ payload: Data) {
        control?.send(content: CtrlCodec.frame(type, payload), completion: .contentProcessed { _ in })
    }

    private func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
        }
        return v
    }

    public func sendDatagram(_ data: Data) {
        guard phase == .established else { return }
        
        if let header = PacketHeader.decode(data), header.type == .control {
            if data.count > PacketHeader.size && data[PacketHeader.size] == ControlSubType.ping.rawValue {
                dataSocket?.sendTo(data, host: relayHost, port: relayUdpPort)
                return
            }
            sendCtrl(.data, data)
            return
        }
        
        guard let header = PacketHeader.decode(data) else {
            sendCtrl(.data, data)
            return
        }
        let payload = data.subdata(in: PacketHeader.size..<data.count)
        
        let maxFragPayload = 1200 - PacketHeader.size
        if payload.count <= maxFragPayload {
            dataSocket?.sendTo(data, host: relayHost, port: relayUdpPort)
            return
        }
        
        let fragCount = UInt16((payload.count + maxFragPayload - 1) / maxFragPayload)
        for i in 0..<fragCount {
            let start = Int(i) * maxFragPayload
            let end = min(start + maxFragPayload, payload.count)
            let fragPayload = payload.subdata(in: start..<end)
            let fragHeader = PacketHeader(type: header.type, flags: header.flags, frameId: header.frameId, fragIndex: i, fragCount: fragCount, payloadLength: UInt32(fragPayload.count))
            var fragData = fragHeader.encode()
            fragData.append(fragPayload)
            dataSocket?.sendTo(fragData, host: relayHost, port: relayUdpPort)
        }
    }
}

private final class UDPFragAssembler {
    private var frames: [UInt32: (count: UInt16, parts: [UInt16: Data])] = [:]
    private let lock = NSLock()
    
    func push(header: PacketHeader, payload: Data) -> Data? {
        guard header.fragCount > 1 else { return payload }
        
        lock.lock()
        defer { lock.unlock() }
        
        var frame = frames[header.frameId] ?? (count: header.fragCount, parts: [:])
        frame.parts[header.fragIndex] = payload
        frames[header.frameId] = frame
        
        guard frame.parts.count == Int(frame.count) else { return nil }
        
        var complete = Data()
        for i in 0..<frame.count {
            guard let part = frame.parts[i] else {
                frames.removeValue(forKey: header.frameId)
                return nil
            }
            complete.append(part)
        }
        frames.removeValue(forKey: header.frameId)
        return complete
    }
}