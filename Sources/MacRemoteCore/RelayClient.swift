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
    private var endpoints: [String: sockaddr_in] = [:]

    var onDatagram: ((Data, String, UInt16) -> Void)?
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
        let descriptor = fd
        src.setCancelHandler {
            Darwin.close(descriptor)
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
            var address = addr.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return }
            onDatagram?(Data(recvBuf[0..<Int(n)]), String(cString: text), UInt16(bigEndian: addr.sin_port))
        }
    }

    func sendTo(_ data: Data, host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.fd >= 0 else { return }
            guard let sin = self.resolve(host: host, port: port) else {
                self.onState?("resolve failed: \(host)")
                return
            }
            data.withUnsafeBytes { ptr in
                withUnsafePointer(to: sin) { sinPtr in
                    sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                        _ = sendto(self.fd, ptr.baseAddress, data.count, 0,
                                   saddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func resolve(host: String, port: UInt16) -> sockaddr_in? {
        let key = "\(host):\(port)"
        if let cached = endpoints[key] { return cached }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        guard let aiAddr = first.pointee.ai_addr else { return nil }
        let address = aiAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        endpoints[key] = address
        return address
    }

    func matches(host: String, port: UInt16, address: String, sourcePort: UInt16) -> Bool {
        guard port == sourcePort, let expected = resolve(host: host, port: port) else { return false }
        var actual = in_addr()
        guard inet_pton(AF_INET, address, &actual) == 1 else { return false }
        return expected.sin_addr.s_addr == actual.s_addr
    }

    func close() {
        source?.cancel()
        source = nil
        fd = -1
    }

    deinit { close() }
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

    private var peerHost: String?
    private var peerPort: UInt16 = 0
    private var path = RelayPath()
    private var reportedRoute: RelayPath.Route?
    private var probes: [UInt8: (token: UInt64, sentAt: TimeInterval)] = [:]
    private var bindTimer: DispatchSourceTimer?
    private var bindPacket = Data()
    private var reconnecting = false
    private let sendLock = NSLock()
    private var pendingVideoBytes = 0
    private let maxPendingVideoBytes = 256 * 1024

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
        queue.async { [weak self] in self?.connect() }
    }

    private func connect() {
        phase = .awaitingChallenge
        let conn = NWConnection(
            host: NWEndpoint.Host(relayHost),
            port: NWEndpoint.Port(rawValue: controlPort)!,
            using: .tcp
        )
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.control === conn else { return }
            switch state {
            case .ready:
                self.onState?("relay control connected")
            case .failed(let error):
                self.onState?("relay control failed: \(error)")
                self.reconnectOnQueue()
            case .waiting(let error):
                self.onState?("relay control waiting: \(error)")
                self.reconnectOnQueue()
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
        queue.async { [weak self] in self?.reconnectOnQueue() }
    }

    private func reconnectOnQueue() {
        guard !reconnecting else { return }
        reconnecting = true
        phase = .disconnected
        buffer = Data()
        pingTimer?.cancel(); pingTimer = nil
        bindTimer?.cancel(); bindTimer = nil
        control?.stateUpdateHandler = nil
        control?.cancel()
        control = nil
        dataSocket?.close()
        dataSocket = nil
        peerHost = nil
        peerPort = 0
        path = RelayPath()
        probes.removeAll()
        fragAssembler.reset()
        onState?("relay reconnecting in 3s...")
        queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self else { return }
            self.reconnecting = false
            self.connect()
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
                self.reconnectOnQueue()
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func scheduleControlReceive() {
        guard let connection = control else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, isComplete, error in
            guard let self, self.control === connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.onState?("relay control closed (\(error?.localizedDescription ?? "EOF"))")
                self.reconnectOnQueue()
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
            guard len <= 4 * 1024 * 1024 else {
                onState?("relay control frame exceeds size limit")
                reconnectOnQueue()
                return
            }
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
        bindTimer?.cancel()
        dataSocket?.close()
        peerHost = nil
        peerPort = 0
        path = RelayPath()
        reportedRoute = nil
        probes.removeAll()
        fragAssembler.reset()

        let sock = RawUDPSocket(queue: queue)
        sock.onDatagram = { [weak self] data, address, port in
            self?.handleDataDatagram(data, address: address, port: port)
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
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dataSocket?.sendTo(self.bindPacket, host: self.relayHost, port: self.relayUdpPort)
            self.sendProbes()
            self.reportRoute()
        }
        timer.resume()
        bindTimer = timer

        phase = .established
        onState?("relay session \(sessionId) ready (TCP fallback, probing UDP \(udpPort))")
    }

    // MARK: - Data datagram handling (RPEP, PUNCH, or mac_remote packet)

    private let fragAssembler = UDPFragAssembler()

    private func handleDataDatagram(_ data: Data, address: String, port: UInt16) {
        let fromRelay = dataSocket?.matches(host: relayHost, port: relayUdpPort, address: address, sourcePort: port) == true
        let fromPeer = address == peerHost && port == peerPort
        guard fromRelay || fromPeer else { return }
        if data.count == 22, data.prefix(4) == Data("RMPB".utf8) {
            guard readLE64(data, 4) == sessionId else { return }
            let route = data[12]
            guard route <= 1, (route == 0 ? fromRelay : fromPeer) else { return }
            if data[13] == 0 {
                var response = data
                response[13] = 1
                dataSocket?.sendTo(response, host: address, port: port)
            } else if data[13] == 1, let probe = probes[route],
                      probe.token == readLE64(data, 14),
                      ProcessInfo.processInfo.systemUptime - probe.sentAt < 3 {
                path.acknowledge(direct: route == 1, at: ProcessInfo.processInfo.systemUptime)
                probes.removeValue(forKey: route)
                reportRoute()
            }
            return
        }
        // Keep bind timer running to refresh NAT mapping and relay address record
        // RPEP: peer endpoint info from relay
        if fromRelay, data.count >= 7, data[0..<4] == Data([0x52, 0x50, 0x45, 0x50]) {
            parsePeerEndpoint(data)
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
        path = RelayPath()
        probes.removeAll()
        onState?("peer endpoint: \(ip):\(port) - probing direct route")
    }

    private func sendProbes() {
        let now = ProcessInfo.processInfo.systemUptime
        for route: UInt8 in [0, 1] {
            guard route == 0 || peerHost != nil else { continue }
            if let pending = probes[route], now - pending.sentAt < 3 { continue }
            let token = UInt64.random(in: 1...UInt64.max)
            probes[route] = (token, now)
            var probe = Data("RMPB".utf8)
            probe.appendLE(sessionId)
            probe.append(route)
            probe.append(0)
            probe.appendLE(token)
            dataSocket?.sendTo(probe, host: route == 0 ? relayHost : peerHost!,
                               port: route == 0 ? relayUdpPort : peerPort)
        }
    }

    private func reportRoute() {
        let route = path.route(at: ProcessInfo.processInfo.systemUptime)
        if route != reportedRoute {
            reportedRoute = route
            onState?("video route: \(route.rawValue)")
        }
    }

    // MARK: - Sending

    private func sendCtrl(_ type: CtrlFrameType, _ payload: Data, completion: @escaping () -> Void = {}) {
        guard let connection = control else { completion(); return }
        connection.send(content: CtrlCodec.frame(type, payload), completion: .contentProcessed { _ in completion() })
    }

    private func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
        }
        return v
    }

    @discardableResult
    public func sendDatagram(_ data: Data) -> Bool {
        guard let header = PacketHeader.decode(data) else { return false }
        let cost = header.type == .video || header.type == .region ? data.count : 0
        sendLock.lock()
        guard pendingVideoBytes + cost <= maxPendingVideoBytes else {
            sendLock.unlock()
            return false
        }
        pendingVideoBytes += cost
        sendLock.unlock()
        queue.async { [weak self] in
            self?.sendOnQueue(data) { [weak self] in
                guard let self else { return }
                self.sendLock.lock()
                self.pendingVideoBytes -= cost
                self.sendLock.unlock()
            }
        }
        return true
    }

    private func sendOnQueue(_ data: Data, completion: @escaping () -> Void) {
        guard phase == .established, let header = PacketHeader.decode(data) else { completion(); return }
        let route = path.route(at: ProcessInfo.processInfo.systemUptime)
        if header.type == .control || header.type == .input || route == .tcp {
            sendCtrl(.data, data, completion: completion)
            return
        }
        defer { completion() }
        let destination = route == .direct ? (peerHost ?? relayHost) : relayHost
        let destinationPort = route == .direct ? peerPort : relayUdpPort
        let payload = data.subdata(in: PacketHeader.size..<data.count)
        
        let maxFragPayload = 1200 - PacketHeader.size
        if payload.count <= maxFragPayload {
            dataSocket?.sendTo(data, host: destination, port: destinationPort)
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
            dataSocket?.sendTo(fragData, host: destination, port: destinationPort)
        }
    }
}

final class UDPFragAssembler {
    private var frames: [UInt64: (count: UInt16, parts: [UInt16: Data], started: TimeInterval)] = [:]
    private let lock = NSLock()

    func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }
    
    func push(header: PacketHeader, payload: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data? {
        guard header.fragCount > 0, header.fragCount <= 256,
              header.fragIndex < header.fragCount,
              payload.count == Int(header.payloadLength), payload.count <= 1200 else { return nil }
        guard header.fragCount > 1 else { return payload }
        lock.lock()
        defer { lock.unlock() }
        frames = frames.filter { now - $0.value.started < 1 }
        let key = UInt64(header.type.rawValue) << 32 | UInt64(header.frameId)
        if frames[key] == nil, frames.count >= 64,
           let oldest = frames.min(by: { $0.value.started < $1.value.started })?.key {
            frames.removeValue(forKey: oldest)
        }
        var frame = frames[key] ?? (count: header.fragCount, parts: [:], started: now)
        guard frame.count == header.fragCount else {
            frames.removeValue(forKey: key)
            return nil
        }
        frame.parts[header.fragIndex] = payload
        frames[key] = frame
        
        guard frame.parts.count == Int(frame.count) else { return nil }
        
        var complete = Data()
        for i in 0..<frame.count {
            guard let part = frame.parts[i] else {
                frames.removeValue(forKey: key)
                return nil
            }
            complete.append(part)
        }
        frames.removeValue(forKey: key)
        return complete
    }
}