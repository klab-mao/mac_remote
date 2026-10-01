import XCTest
@testable import MacRemoteCore

final class RelayPathTests: XCTestCase {
    func testBlockedUDPUsesTCP() {
        let path = RelayPath()
        XCTAssertEqual(path.route(at: 0), .tcp)
        XCTAssertEqual(path.route(at: 100), .tcp)
    }

    func testRelayRequiresFreshAcknowledgment() {
        var path = RelayPath()
        path.acknowledge(direct: false, at: 10)
        XCTAssertEqual(path.route(at: 12), .udp)
        XCTAssertEqual(path.route(at: 13), .tcp)
        path.acknowledge(direct: false, at: 14)
        XCTAssertEqual(path.route(at: 14), .udp)
    }

    func testDirectFailureFallsBackToRelayThenTCP() {
        var path = RelayPath()
        path.acknowledge(direct: true, at: 10)
        path.acknowledge(direct: false, at: 12)
        XCTAssertEqual(path.route(at: 12), .direct)
        XCTAssertEqual(path.route(at: 13), .udp)
        XCTAssertEqual(path.route(at: 15), .tcp)
    }

    func testNewSessionStartsOnTCP() {
        var path = RelayPath()
        path.acknowledge(direct: true, at: 10)
        path = RelayPath()
        XCTAssertEqual(path.route(at: 10), .tcp)
    }
}