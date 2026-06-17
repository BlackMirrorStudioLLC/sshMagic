import XCTest

@testable import sshMagic

final class HostKeyCheckTests: XCTestCase {
    /// The real OpenSSH banner must be classified as a changed key, and the new
    /// SHA256 fingerprint pulled out (trailing period stripped).
    func testParsesChangedHostKeyWarning() {
        let stderr = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Someone could be eavesdropping on you right now (man-in-the-middle attack)!
            It is also possible that a host key has just been changed.
            The fingerprint for the ED25519 key sent by the remote host is
            SHA256:wsJCJx+FOsWiaVyjCWD/+WqYeezbs0S80XwhXM/VjC8.
            Please contact your system administrator.
            Host key for 192.168.1.112 has changed and you have requested strict checking.
            Host key verification failed.
            """

        let result = HostKeyCheck.parse(stderr)
        XCTAssertEqual(
            result,
            HostKeyCheck.ChangedKey(
                newFingerprint: "SHA256:wsJCJx+FOsWiaVyjCWD/+WqYeezbs0S80XwhXM/VjC8"))
    }

    /// A changed-key banner without a parseable fingerprint still classifies as
    /// changed (we still want to offer the overwrite), just with no fingerprint.
    func testChangedKeyWithoutFingerprint() {
        let result = HostKeyCheck.parse("REMOTE HOST IDENTIFICATION HAS CHANGED!\nfailed.")
        XCTAssertEqual(result, HostKeyCheck.ChangedKey(newFingerprint: nil))
    }

    /// An ordinary auth failure (or any non-host-key error) must NOT be mistaken
    /// for a changed key — otherwise every wrong password would offer to nuke a
    /// host key.
    func testAuthFailureIsNotAChangedKey() {
        XCTAssertNil(HostKeyCheck.parse("Permission denied (publickey,password)."))
        XCTAssertNil(HostKeyCheck.parse("ssh: connect to host 10.0.0.9 port 22: Connection refused"))
        XCTAssertNil(HostKeyCheck.parse(""))
    }
}
