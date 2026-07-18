import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest
@testable import FerryCore

/// Byte-level tests for the `SSHChannelData ↔ ByteBuffer` codec that remote
/// forwards install on `forwarded-tcpip` channels (M14.5, ADR-022). Pure
/// `EmbeddedChannel`, no server.
final class SSHChannelDataCodecTests: XCTestCase {

    func testInboundChannelDataBecomesByteBuffer() throws {
        let channel = EmbeddedChannel(handler: SSHChannelDataCodec())
        var buffer = channel.allocator.buffer(capacity: 5)
        buffer.writeString("hello")

        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
        let unwrapped: ByteBuffer? = try channel.readInbound()
        XCTAssertEqual(unwrapped.map { String(buffer: $0) }, "hello")
        _ = try? channel.finish()
    }

    func testInboundStdErrIsRejected() throws {
        let channel = EmbeddedChannel(handler: SSHChannelDataCodec())
        var buffer = channel.allocator.buffer(capacity: 4)
        buffer.writeString("oops")

        var caught: Error?
        do {
            try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)))
            try channel.throwIfErrorCaught()
        } catch {
            caught = error
        }
        XCTAssertTrue(caught is SSHChannelDataCodec.UnexpectedSSHData,
                      "expected UnexpectedSSHData, got: \(String(describing: caught))")
        // Nothing must leak past the codec.
        let leaked: ByteBuffer? = try channel.readInbound()
        XCTAssertNil(leaked)
        _ = try? channel.finish()
    }

    func testOutboundByteBufferIsWrapped() throws {
        let channel = EmbeddedChannel(handler: SSHChannelDataCodec())
        var buffer = channel.allocator.buffer(capacity: 5)
        buffer.writeString("reply")

        try channel.writeOutbound(buffer)
        guard let wrapped: SSHChannelData = try channel.readOutbound() else {
            return XCTFail("nothing written outbound")
        }
        XCTAssertEqual(wrapped.type, .channel)
        guard case .byteBuffer(let bytes) = wrapped.data else {
            return XCTFail("expected byteBuffer payload")
        }
        XCTAssertEqual(String(buffer: bytes), "reply")
        _ = try? channel.finish()
    }
}
