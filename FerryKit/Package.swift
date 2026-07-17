// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FerryKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FerryCore", targets: ["FerryCore"])
    ],
    dependencies: [
        // SSH/SFTP client (MIT, over swift-nio-ssh Apache-2.0) — ADR-003/ADR-011,
        // licenses recorded in docs/LICENSING.md.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0"),
        // Apple swift-crypto (Apache-2.0) — already in the graph transitively via
        // Citadel; made a direct dependency at M11 so host-key fingerprints (SHA256)
        // and private-key parsing name the SAME Curve25519/RSA types Citadel's
        // OpenSSH initializers extend (Crypto, not CryptoKit). ADR-017, LICENSING.md.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0")
    ],
    targets: [
        // Thin C shim over the system libcurl (curl license — nothing bundled,
        // ADR-003/ADR-019). Exposes libcurl's variadic setopt/getinfo as
        // concrete functions Swift can call; links `/usr/lib/libcurl`.
        .target(name: "CFTP", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "FerryCore",
                dependencies: ["CFTP",
                               .product(name: "Citadel", package: "Citadel"),
                               .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore"]),
        // Integration tests talk to the local Docker test servers (testinfra/).
        // They skip themselves when the servers are down, unless
        // FERRY_REQUIRE_TEST_SERVERS=1 turns absence into a failure (CI mode).
        .testTarget(name: "FerryIntegrationTests", dependencies: ["FerryCore"])
    ]
)
