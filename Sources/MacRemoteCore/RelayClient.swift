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

public final class RelayTransport: Transport {
    public var onPacket: ((PacketHeader, Data) -> Void)?
    public var onState: ((String) -> Void)?

    private let relayHost: String
    private let controlPort: UInt16
    private let role: RelayRole
    private let secret: String

    private let queue = DispatchQueue(label: "mac_remote.relay")
    private var control: NWConnection?
    private var dataFlow: UDPFlow?
    private var buffer = Data()
    private var nonce = Data()
    private var phase: Phase = .disconnected
    private var sessionId: UInt64 = 0
    private var pingTimer: DispatchSourceTimer?

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

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.sendCtrl(.ping, Data())
        }
        timer.resume()
        pingTimer = timer
    }

    private func scheduleControlReceive() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.onState?("relay control closed (\(error?.localizedDescription ?? "EOF"))")
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
            guard let type = CtrlFrameType(rawValue: typeRaw) else { continue }
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
                if case .viewer = role {
                    if case .viewer(_, let deviceId) = role {
                        sendCtrl(.connectReq, CtrlCodec.namePayload(deviceId))
                    }
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
            break
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
        let flow = UDPFlow(host: relayHost, port: udpPort)
        flow.onPacket = { [weak self] header, payload in
            self?.onPacket?(header, payload)
        }
        flow.onState = { [weak self] state in
            self?.onState?("relay data: \(state)")
        }
        flow.start()
        dataFlow = flow

        var bind = Data()
        bind.append(contentsOf: Array("RMBD".utf8))
        bind.appendLE(sessionId)
        let side: UInt8
        if case .host = role { side = 1 } else { side = 2 }
        bind.append(side)
        flow.sendDatagram(bind)

        phase = .established
        onState?("relay session \(sessionId) ready (udp \(udpPort))")
    }

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
        dataFlow?.sendDatagram(data)
    }

    public func send(type: PacketType, flags: UInt8, frameId: UInt32, fragIndex: UInt16, fragCount: UInt16, payload: Data) {
        guard phase == .established else { return }
        dataFlow?.send(type: type, flags: flags, frameId: frameId, fragIndex: fragIndex, fragCount: fragCount, payload: payload)
    }

    public func sendControl(_ subType: ControlSubType, extra: Data) {
        guard phase == .established else { return }
        dataFlow?.sendControl(subType, extra: extra)
    }
}