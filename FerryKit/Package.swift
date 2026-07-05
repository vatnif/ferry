// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FerryKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FerryCore", targets: ["FerryCore"])
    ],
    targets: [
        .target(name: "FerryCore"),
        .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore"]),
        // Integration tests talk to the local Docker test servers (testinfra/).
        // They skip themselves when the servers are down, unless
        // FERRY_REQUIRE_TEST_SERVERS=1 turns absence into a failure (CI mode).
        .testTarget(name: "FerryIntegrationTests", dependencies: ["FerryCore"])
    ]
)
