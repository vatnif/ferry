import XCTest
@testable import FerryCore

/// Size-ladder regression test for SFTP uploads (born as the diagnostic that
/// exposed the M8 root-owned-upload-dir bug): uploads of increasing size
/// straight through SFTPSource, each guarded by a 20 s timeout so a wedged
/// write fails instead of hanging the suite.
final class SFTPWriteProbeTests: XCTestCase {
    func testUploadSizeLadder() async throws {
        _ = try TestServers.requireGreeting(port: TestServers.sftpPort, serverName: "SFTP")
        let source = try await TestServers.connectSFTP()
        defer { Task { [source] in await source.disconnect() } }

        for sizeKB in [64, 256, 512, 1024, 2048] {
            let payload = Data(repeating: 0x5A, count: sizeKB * 1024)
            let remotePath = "/upload/probe-\(sizeKB)kb.bin"
            let started = Date()

            let done = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let handle = try await source.openWrite(at: remotePath, offset: 0)
                    // Feed in 256 KiB slices like the engine does.
                    var index = payload.startIndex
                    while index < payload.endIndex {
                        let end = min(index + 256 * 1024, payload.endIndex)
                        try await handle.write(payload[index..<end])
                        index = end
                    }
                    try await handle.close()
                    return true
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    return false
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }

            print("PROBE size=\(sizeKB)KB done=\(done) elapsed=\(String(format: "%.1f", -started.timeIntervalSinceNow))s")
            XCTAssertTrue(done, "upload of \(sizeKB)KB timed out after 20s")
            let stat = try await source.stat(path: remotePath)
            XCTAssertEqual(stat.size, Int64(payload.count), "size mismatch at \(sizeKB)KB")
            try await source.delete(at: remotePath)
        }
    }
}
