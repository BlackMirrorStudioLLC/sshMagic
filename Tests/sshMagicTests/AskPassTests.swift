import XCTest

@testable import sshMagic

final class AskPassTests: XCTestCase {
    /// Run the generated helper exactly as ssh would (it execs SSH_ASKPASS and
    /// reads stdout) and confirm it emits the password — repeatedly. The helper
    /// deliberately does NOT self-delete: OpenSSH may invoke askpass more than
    /// once per session (a retry, or a host-key confirm before the password),
    /// and a consumed file would feed an empty password on the second call. The
    /// backing file is removed when the session ends (cleanup of cleanupURL).
    func testHelperEmitsPasswordOnRepeatedInvocations() throws {
        let password = "p@ss w0rd! with spaces & 'quotes'"
        guard let setup = AskPass.make(password: password) else {
            return XCTFail("AskPass.make returned nil")
        }

        // ssh requires SSH_ASKPASS_REQUIRE=force to use the helper despite a tty.
        XCTAssertTrue(setup.environment.contains("SSH_ASKPASS_REQUIRE=force"))

        let askpassEntry = try XCTUnwrap(
            setup.environment.first { $0.hasPrefix("SSH_ASKPASS=") })
        let scriptPath = String(askpassEntry.dropFirst("SSH_ASKPASS=".count))

        XCTAssertEqual(try runHelper(scriptPath), password)
        // Idempotent across invocations within the session.
        XCTAssertEqual(try runHelper(scriptPath), password)

        // Cleanup removes the backing file, after which the helper emits nothing.
        AskPass.cleanup(setup.cleanupURL)
        XCTAssertEqual(try runHelper(scriptPath), "")
    }

    func testNoPasswordIsNotInArgsOrEnvironment() throws {
        // Sanity: the password never appears in the env entries themselves — only
        // a path to the helper does.
        let password = "TOPSECRET12345"
        let setup = try XCTUnwrap(AskPass.make(password: password))
        defer { AskPass.cleanup(setup.cleanupURL) }
        for entry in setup.environment {
            XCTAssertFalse(entry.contains(password), "password leaked into env: \(entry)")
        }
    }

    private func runHelper(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
