import XCTest

@testable import sshMagic

final class HostTests: XCTestCase {
    func testDefaultPortOmitsPortFlag() {
        let host = Host(hostname: "10.0.0.5", username: "pi")
        XCTAssertEqual(host.sshArguments, ["pi@10.0.0.5"])
    }

    func testNonDefaultPortAddsFlag() {
        let host = Host(hostname: "example.com", port: 2222, username: "root")
        XCTAssertEqual(host.sshArguments, ["-p", "2222", "root@example.com"])
    }

    func testUserAtHostWithoutUsername() {
        let host = Host(hostname: "nas.local")
        XCTAssertEqual(host.userAtHost, "nas.local")
        XCTAssertEqual(host.sshArguments, ["nas.local"])
    }

    func testIDCollapsesSameEndpoint() {
        let a = Host(hostname: "10.0.0.5", port: 22, source: .bonjour)
        let b = Host(hostname: "10.0.0.5", port: 22, source: .scan)
        XCTAssertEqual(a.id, b.id)
    }

    func testEmptyUsernameTreatedAsNone() {
        let host = Host(hostname: "host", username: "")
        XCTAssertEqual(host.userAtHost, "host")
    }
}
