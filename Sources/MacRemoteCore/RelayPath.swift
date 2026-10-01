import Foundation

struct RelayPath {
    enum Route: String {
        case tcp = "TCP relay"
        case udp = "UDP relay"
        case direct = "direct UDP"
    }

    private var relayAcknowledgedAt: TimeInterval?
    private var directAcknowledgedAt: TimeInterval?
    private let timeout: TimeInterval = 3

    mutating func acknowledge(direct: Bool, at time: TimeInterval) {
        if direct {
            directAcknowledgedAt = time
        } else {
            relayAcknowledgedAt = time
        }
    }

    func route(at time: TimeInterval) -> Route {
        if let last = directAcknowledgedAt, time - last < timeout {
            return .direct
        }
        if let last = relayAcknowledgedAt, time - last < timeout {
            return .udp
        }
        return .tcp
    }
}