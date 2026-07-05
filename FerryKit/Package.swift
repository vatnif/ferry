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
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0")
    ],
    targets: [
        .target(name: "FerryCore",
                dependencies: [.product(name: "Citadel", package: "Citadel")]),
        .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore"]),
        // Integration tests talk to the local Docker test servers (testinfra/).
        // They skip themselves when the servers are down, unless
        // FERRY_REQUIRE_TEST_SERVERS=1 turns absence into a failure (CI mode).
        .testTarget(name: "FerryIntegrationTests", dependencies: ["FerryCore"])
    ]
)
