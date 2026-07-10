import XCTest

@testable import sshMagic

final class KnownHostsTests: XCTestCase {
    /// A default-port host owns the bare known_hosts line; the bracket form is
    /// also tried because some IPv6 entries are recorded bracketed even on 22.
    func testPort22TargetsBareAndBracketForms() {
        XCTAssertEqual(
            KnownHosts.removalTargets(for: Host(hostname: "nas.local")),
            ["nas.local", "[nas.local]:22"])
    }

    /// A non-default-port host must touch ONLY its bracketed entry. The bare
    /// line belongs to the port-22 endpoint — possibly a different saved host
    /// on the same machine — and deleting it would let the next port-22
    /// connect (made with accept-new) silently trust whatever key the network
    /// presents.
    func testNonDefaultPortTargetsOnlyBracketForm() {
        XCTAssertEqual(
            KnownHosts.removalTargets(for: Host(hostname: "nas.local", port: 2222)),
            ["[nas.local]:2222"])
    }

    func testIPv6NonDefaultPortTargetsOnlyBracketForm() {
        XCTAssertEqual(
            KnownHosts.removalTargets(for: Host(hostname: "fe80::1", port: 2200)),
            ["[fe80::1]:2200"])
    }
}
