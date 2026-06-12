import XCTest

@testable import sshMagic

final class SubnetScannerTests: XCTestCase {
    /// Regression test for the libdispatch deadlock/trap that crashed the app on
    /// "Scan network": the driver loop blocked on a semaphore that could only be
    /// signalled from the *same* serial queue, and `isCancelled` did a reentrant
    /// `queue.sync`. A correct scan must always reach `onComplete` — the old code
    /// either trapped (dispatch_sync on the owning queue) or hung here.
    func testScanReachesCompletionWithoutDeadlock() {
        let scanner = SubnetScanner(maxConcurrent: 64, connectTimeout: 0.3)
        let done = expectation(description: "scan completes")

        scanner.scan(
            onFound: { _ in },
            onComplete: { done.fulfill() }
        )

        // Generous bound so network size/latency on the CI runner can't flake
        // it: a hang (the original bug) trips the timeout; a trap crashes the
        // process. The real sweep runs in the background in the app, so its
        // wall-clock here only matters for the test.
        wait(for: [done], timeout: 90)
    }

    /// Regression test for the "Semaphore object deallocated while in use" trap:
    /// dropping the caller's only reference mid-sweep (exactly what
    /// `DiscoveryManager` does when it nils `subnet`) must NOT deinit the scanner
    /// while probes are still in flight. The driver loop holds `self` strongly
    /// until `group.wait()` returns, so the run completes and the semaphore is
    /// balanced at dealloc.
    func testSurvivesCallerReleasingReferenceMidScan() {
        let done = expectation(description: "scan completes after caller drops ref")

        // Scope the scanner so the only strong reference is gone before the
        // sweep finishes; if lifetime weren't pinned by the driver, this traps.
        do {
            let scanner = SubnetScanner(maxConcurrent: 64, connectTimeout: 0.3)
            scanner.scan(
                onFound: { _ in },
                onComplete: { done.fulfill() }
            )
        }

        wait(for: [done], timeout: 90)
    }

    /// Cancelling mid-sweep must still drive the run to completion (every
    /// outstanding slot is released) rather than wedging.
    func testCancelStillCompletes() {
        let scanner = SubnetScanner(maxConcurrent: 16, connectTimeout: 1.0)
        let done = expectation(description: "cancelled scan completes")

        scanner.scan(
            onFound: { _ in },
            onComplete: { done.fulfill() }
        )
        scanner.cancel()

        wait(for: [done], timeout: 30)
    }
}
