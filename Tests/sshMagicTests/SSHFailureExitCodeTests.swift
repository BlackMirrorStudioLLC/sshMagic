import XCTest

@testable import sshMagic

/// Locks in the dual-encoding contract for detecting ssh's exit 255 from the
/// status SwiftTerm reports. If SwiftTerm ever normalises its delivery, this at
/// least keeps the decoding logic explicit and covered.
final class SSHFailureExitCodeTests: XCTestCase {
    func testDetectsSSHFailureInBothEncodings() {
        // Extracted code (one SwiftTerm path) and raw waitpid status 0xFF00
        // (the other path) both mean ssh exited 255.
        XCTAssertTrue(TerminalSession.isSSHFailure(exitCode: 255))
        XCTAssertTrue(TerminalSession.isSSHFailure(exitCode: 65280))
    }

    func testIgnoresNonFailureExits() {
        XCTAssertFalse(TerminalSession.isSSHFailure(exitCode: 0))  // clean logout
        XCTAssertFalse(TerminalSession.isSSHFailure(exitCode: 1))  // remote `exit 1` (extracted)
        XCTAssertFalse(TerminalSession.isSSHFailure(exitCode: 256))  // remote `exit 1` (raw 0x0100)
        XCTAssertFalse(TerminalSession.isSSHFailure(exitCode: 9))  // SIGKILL-style status
        XCTAssertFalse(TerminalSession.isSSHFailure(exitCode: nil))  // IO error
        XCTAssertFalse(TerminalSession.isSSHFailure(exitCode: -1))  // negative: no sign-extension hit
    }
}
