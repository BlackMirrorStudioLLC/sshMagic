import XCTest

@testable import sshMagic

final class RemoteFileParseTests: XCTestCase {
    /// A realistic OpenSSH `sftp> ls -la` dump.
    private let sample = """
        sftp> ls -la /home/astro
        drwxr-xr-x    5 astro    astro        4096 Jun 12 14:00 .
        drwxr-xr-x    3 root     root         4096 Jan 01  2024 ..
        drwxr-xr-x    2 astro    astro        4096 Jun 10 09:12 .cache
        -rw-r--r--    1 astro    astro         220 Jan 01  2024 .bash_logout
        -rw-r--r--    1 astro    astro       12480 Jun 12 13:59 notes.txt
        lrwxrwxrwx    1 astro    astro          11 Jun 01 08:00 www -> /var/www
        drwxr-xr-x    2 astro    astro        4096 Jun 02 10:00 My Projects
        """

    /// Some sftp servers prefix every entry with the full directory path when
    /// listing an explicit path — names must reduce to the basename, and the
    /// path-prefixed "." / ".." must still be filtered out.
    func testFullPathPrefixedEntriesReduceToBasename() {
        let prefixed = """
            drwxr-xr-x    5 astro astro 4096 Jun 14 14:00 /home/astro/.
            drwxr-xr-x    3 root  root  4096 Jan 01  2024 /home/astro/..
            -rw-r--r--    1 astro astro  495 Jun 14 13:59 /home/astro/.bash_history
            drwxr-xr-x    2 astro astro 4096 Jun 10 09:12 /home/astro/.cache
            lrwxrwxrwx    1 astro astro   11 Jun 01 08:00 /home/astro/www -> /var/www
            """
        let files = RemoteFile.parse(lsOutput: prefixed)
        let names = files.map(\.name)
        XCTAssertEqual(names.sorted(), [".bash_history", ".cache", "www"])
        XCTAssertFalse(names.contains { $0.contains("/") })
        XCTAssertFalse(names.contains(".") || names.contains(".."))
        XCTAssertTrue(files.first { $0.name == "www" }?.isSymlink ?? false)
    }

    func testParsesEntriesAndSkipsDotAndPrompt() {
        let files = RemoteFile.parse(lsOutput: sample)
        let names = files.map(\.name)
        XCTAssertFalse(names.contains("."))
        XCTAssertFalse(names.contains(".."))
        XCTAssertFalse(names.contains { $0.contains("sftp>") })
        XCTAssertTrue(names.contains(".cache"))
        XCTAssertTrue(names.contains("notes.txt"))
    }

    func testDirectoriesSortFirstThenNaturalOrder() throws {
        let files = RemoteFile.parse(lsOutput: sample)
        // Directories (.cache, My Projects, www-symlink-not-dir...) before files.
        let firstFile = try XCTUnwrap(files.firstIndex { !$0.isDirectory })
        let lastDir = try XCTUnwrap(files.lastIndex { $0.isDirectory })
        XCTAssertLessThan(lastDir, firstFile)
    }

    func testFileMetadata() throws {
        let files = RemoteFile.parse(lsOutput: sample)
        let notes = try XCTUnwrap(files.first { $0.name == "notes.txt" })
        XCTAssertEqual(notes.size, 12480)
        XCTAssertFalse(notes.isDirectory)
        XCTAssertEqual(notes.modified, "Jun 12 13:59")
    }

    func testSymlinkNameStripsTarget() {
        let files = RemoteFile.parse(lsOutput: sample)
        let link = files.first { $0.name == "www" }
        XCTAssertNotNil(link, "symlink should keep just its name, not '-> target'")
        XCTAssertTrue(link?.isSymlink ?? false)
    }

    func testNameWithSpacesPreserved() {
        let files = RemoteFile.parse(lsOutput: sample)
        XCTAssertTrue(files.contains { $0.name == "My Projects" && $0.isDirectory })
    }

    func testNonListingLinesIgnored() {
        let junk = """
            Connected to host.
            sftp> ls
            Permission denied
            """
        XCTAssertTrue(RemoteFile.parse(lsOutput: junk).isEmpty)
    }

    func testSizeFormattingAndIcons() {
        let dir = RemoteFile(name: "x", isDirectory: true, isSymlink: false, size: 4096, modified: "")
        XCTAssertEqual(dir.sizeText, "")
        XCTAssertEqual(dir.icon, "folder.fill")

        let img = RemoteFile(name: "p.png", isDirectory: false, isSymlink: false, size: 2048, modified: "")
        XCTAssertEqual(img.icon, "photo")
        XCTAssertFalse(img.sizeText.isEmpty)
    }
}
