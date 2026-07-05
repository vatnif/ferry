import Foundation
import XCTest

/// Connection details for the local Docker test servers (see testinfra/).
/// Keep in sync with testinfra/docker-compose.yml.
enum TestServers {
    static let host = "127.0.0.1"
    static let sftpPort: UInt16 = 2222
    static let ftpPort: UInt16 = 2121
    static let username = "ferry"
    static let password = "ferrypass"

    /// Opens a TCP connection and returns the server's greeting line,
    /// or nil if the port is unreachable. Synchronous on purpose —
    /// loopback connects resolve instantly and this avoids any
    /// continuation bookkeeping in test code.
    static func readGreeting(port: UInt16, timeoutSeconds: Int = 3) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    /// Standard gate for every integration test: returns the greeting, or
    /// handles the servers-down case (skip locally, fail when
    /// FERRY_REQUIRE_TEST_SERVERS=1, e.g. in CI).
    static func requireGreeting(port: UInt16, serverName: String) throws -> String {
        if let greeting = readGreeting(port: port) { return greeting }
        let message = "\(serverName) test server is not reachable on port \(port). " +
                      "Start it with: testinfra/start.sh"
        if ProcessInfo.processInfo.environment["FERRY_REQUIRE_TEST_SERVERS"] == "1" {
            XCTFail(message)
            return ""
        }
        throw XCTSkip(message)
    }
}
