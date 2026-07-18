import XCTest
@testable import FerryCore

/// Unit tests for the pure SOCKS5 wire parser behind Ferry's dynamic-proxy
/// tunnels (M14, ADR-021). Byte vectors pin the fragile framing so the live
/// negotiator can be trusted.
final class SOCKSProxyTests: XCTestCase {

    // MARK: Greeting

    func testGreetingNoAuth() {
        let result = SOCKSProxy.parseGreeting([0x05, 0x01, 0x00])
        XCTAssertEqual(result, .greeting(methods: [0x00], bytesConsumed: 3))
    }

    func testGreetingMultipleMethods() {
        let result = SOCKSProxy.parseGreeting([0x05, 0x02, 0x00, 0x02])
        XCTAssertEqual(result, .greeting(methods: [0x00, 0x02], bytesConsumed: 4))
    }

    func testGreetingNeedsMoreData() {
        XCTAssertEqual(SOCKSProxy.parseGreeting([0x05]), .needMoreData)
        // Says 2 methods but only one present.
        XCTAssertEqual(SOCKSProxy.parseGreeting([0x05, 0x02, 0x00]), .needMoreData)
    }

    func testGreetingRejectsWrongVersion() {
        if case .invalid = SOCKSProxy.parseGreeting([0x04, 0x01, 0x00]) { } else {
            XCTFail("SOCKS4 greeting should be rejected")
        }
    }

    // MARK: Request — address types

    func testRequestIPv4() {
        // CONNECT 127.0.0.1:22
        let bytes: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x16]
        XCTAssertEqual(SOCKSProxy.parseRequest(bytes),
                       .connect(SOCKSProxy.Target(host: "127.0.0.1", port: 22), bytesConsumed: 10))
    }

    func testRequestDomain() {
        // CONNECT db.internal:5432
        let host = Array("db.internal".utf8)
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)]
        bytes += host
        bytes += [0x15, 0x38] // 5432
        XCTAssertEqual(SOCKSProxy.parseRequest(bytes),
                       .connect(SOCKSProxy.Target(host: "db.internal", port: 5432),
                                bytesConsumed: 4 + 1 + host.count + 2))
    }

    func testRequestIPv6() {
        // CONNECT [::1]:443
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x04]
        bytes += [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        bytes += [0x01, 0xBB] // 443
        XCTAssertEqual(SOCKSProxy.parseRequest(bytes),
                       .connect(SOCKSProxy.Target(host: "0000:0000:0000:0000:0000:0000:0000:0001",
                                                  port: 443), bytesConsumed: 22))
    }

    func testRequestNeedsMoreData() {
        XCTAssertEqual(SOCKSProxy.parseRequest([0x05, 0x01, 0x00]), .needMoreData)
        // IPv4 header present, address truncated.
        XCTAssertEqual(SOCKSProxy.parseRequest([0x05, 0x01, 0x00, 0x01, 127, 0]), .needMoreData)
        // Domain length known, name truncated.
        XCTAssertEqual(SOCKSProxy.parseRequest([0x05, 0x01, 0x00, 0x03, 0x05, 0x61]), .needMoreData)
    }

    func testRequestRejectsNonConnectCommand() {
        // BIND (0x02) is unsupported.
        if case .rejected(_, let reply) = SOCKSProxy.parseRequest([0x05, 0x02, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) {
            XCTAssertEqual(reply, .commandNotSupported)
        } else {
            XCTFail("BIND should be rejected as command-not-supported")
        }
    }

    func testRequestRejectsUnknownAddressType() {
        if case .rejected(_, let reply) = SOCKSProxy.parseRequest([0x05, 0x01, 0x00, 0x09, 0, 0]) {
            XCTAssertEqual(reply, .addressTypeNotSupported)
        } else {
            XCTFail("unknown ATYP should be rejected")
        }
    }

    // MARK: Replies

    func testMethodSelectionReply() {
        XCTAssertEqual(SOCKSProxy.methodSelectionReply(accepted: true), [0x05, 0x00])
        XCTAssertEqual(SOCKSProxy.methodSelectionReply(accepted: false), [0x05, 0xFF])
    }

    func testConnectReplyFraming() {
        let reply = SOCKSProxy.connectReply(.succeeded)
        XCTAssertEqual(reply, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(SOCKSProxy.connectReply(.connectionRefused)[1], 0x05)
    }
}
