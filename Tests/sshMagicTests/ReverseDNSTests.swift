import XCTest

@testable import sshMagic

final class ReverseDNSTests: XCTestCase {
    func testMalformedAddressReturnsNil() {
        XCTAssertNil(ReverseDNS.hostname(for: "not-an-ip"))
        XCTAssertNil(ReverseDNS.hostname(for: ""))
        XCTAssertNil(ReverseDNS.hostname(for: "999.999.999.999"))
    }

    func testUnresolvableAddressReturnsNil() {
        // TEST-NET-1 (192.0.2.0/24, RFC 5737) is reserved for documentation and
        // has no PTR record, so a reverse lookup must yield nil — not the echoed
        // numeric address.
        XCTAssertNil(ReverseDNS.hostname(for: "192.0.2.123"))
    }
}
