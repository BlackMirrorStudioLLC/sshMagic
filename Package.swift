// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sshMagic",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sshMagic", targets: ["sshMagic"])
    ],
    dependencies: [
        // Embedded VT100/xterm terminal engine + AppKit view. Proven in shipping
        // SSH clients (Secure ShellFish, La Terminal, CodeEdit). Pinned to a
        // release range; Dependabot bumps it.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "sshMagic",
            dependencies: ["SwiftTerm"],
            path: "Sources/sshMagic"
        ),
        .testTarget(
            name: "sshMagicTests",
            dependencies: ["sshMagic"],
            path: "Tests/sshMagicTests"
        )
    ]
)
