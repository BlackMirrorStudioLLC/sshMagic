import XCTest

@testable import sshMagic

final class LocalNetworkTests: XCTestCase {
    func testHostAddressesForSlash24() {
        // 192.168.1.10 / 255.255.255.0
        let iface = LocalNetwork.Interface(
            name: "en0",
            address: 0xC0A8010A,
            netmask: 0xFFFFFF00
        )
        let hosts = LocalNetwork.hostAddresses(for: iface)
        // .1 … .254 minus our own .10 = 253 hosts
        XCTAssertEqual(hosts.count, 253)
        XCTAssertTrue(hosts.contains("192.168.1.1"))
        XCTAssertTrue(hosts.contains("192.168.1.254"))
        XCTAssertFalse(hosts.contains("192.168.1.0"))  // network
        XCTAssertFalse(hosts.contains("192.168.1.255"))  // broadcast
        XCTAssertFalse(hosts.contains("192.168.1.10"))  // self
    }

    func testPhysicalInterfaceFilter() {
        // Physical Wi-Fi / ethernet (and USB/Thunderbolt adapters) are scanned.
        XCTAssertTrue(LocalNetwork.isPhysicalLANInterface("en0"))
        XCTAssertTrue(LocalNetwork.isPhysicalLANInterface("en1"))
        XCTAssertTrue(LocalNetwork.isPhysicalLANInterface("en12"))

        // Virtual interfaces (the ones that ballooned the sweep to 1000+ dead
        // probes across phantom subnets) are excluded.
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("bridge100"))
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("utun4"))
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("awdl0"))
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("llw0"))
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("lo0"))
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("enc"))  // not en + digits
        XCTAssertFalse(LocalNetwork.isPhysicalLANInterface("en"))  // bare
    }

    func testHostAddressesRespectsCap() {
        // A /16 would be 65k hosts; ensure the cap clamps it.
        let iface = LocalNetwork.Interface(
            name: "en0",
            address: 0xC0A80001,
            netmask: 0xFFFF0000
        )
        let hosts = LocalNetwork.hostAddresses(for: iface, maxHosts: 100)
        XCTAssertEqual(hosts.count, 100)
    }
}
