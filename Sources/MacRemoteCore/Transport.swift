import Foundation
import Network

public final class UDPFlow: Transport {
    public var onPacket: ((PacketHeader, Data) -> Void)?
    public var onState: ((String) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public convenience init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.Host(host)
        let conn = NWConnection(host: endpoint, port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.init(connection: conn, queue: DispatchQueue(label: "mac_remote.udp.client"))
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onState?("failed: \(error)")
            } else if case .ready = state {
                self?.onState?("ready")
            }
        }
        connection.start(queue: queue)
        scheduleReceive()
    }

    private func scheduleReceive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if let header = PacketHeader.decode(data) {
                    let payload = data.subdata(in: PacketHeader.size..<data.count)
                    self.onPacket?(header, payload)
                }
            }
            if error == nil {
                self.scheduleReceive()
            } else {
                self.onState?("receive error: \(error!)")
            }
        }
    }

    public func sendDatagram(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { Log.v("UDP send error: \(error)") }
        })
    }

}

public final class UDPListener {
    public var onFlow: ((UDPFlow) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mac_remote.udp.listener")

    public init(port: UInt16) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("Listener failed: \(error)")
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                let flow = UDPFlow(connection: conn, queue: self?.queue ?? DispatchQueue(label: "mac_remote.udp.flow"))
                self?.onFlow?(flow)
            }
            listener = l
        } catch {
            print("Failed to create listener: \(error)")
        }
    }

    public func start() {
        listener?.start(queue: queue)
    }
}