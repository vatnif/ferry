import NIOCore

/// Pure SOCKS5 (RFC 1928) wire parsing for Ferry's dynamic-proxy tunnels
/// (M14, ADR-021). No I/O — it turns raw bytes into decoded greetings and
/// CONNECT requests, so the state machine can be unit-tested with byte vectors.
/// Ferry acts as the SOCKS server on a loopback listener; each CONNECT is
/// satisfied by opening an SSH `direct-tcpip` channel to the requested target.
enum SOCKSProxy {
    static let version: UInt8 = 0x05
    /// Method 0x00 = "no authentication required" — the only one Ferry offers.
    static let methodNoAuth: UInt8 = 0x00
    static let methodNoneAcceptable: UInt8 = 0xFF

    /// Reply codes (RFC 1928 §6).
    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case connectionRefused = 0x05
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    /// The target of a CONNECT request. `host` is the string form ready to hand
    /// to a `direct-tcpip` channel (dotted-quad, bracket-free IPv6, or domain).
    struct Target: Equatable, Sendable {
        var host: String
        var port: Int
    }

    // MARK: Greeting (version-identifier / method-selection)

    enum GreetingResult: Equatable {
        case needMoreData
        case invalid(String)
        /// The offered methods, and how many bytes the greeting consumed.
        case greeting(methods: [UInt8], bytesConsumed: Int)
    }

    static func parseGreeting(_ bytes: [UInt8]) -> GreetingResult {
        guard bytes.count >= 2 else { return .needMoreData }
        guard bytes[0] == version else {
            return .invalid("Unsupported SOCKS version \(bytes[0]); only SOCKS5 is supported.")
        }
        let count = Int(bytes[1])
        guard count > 0 else { return .invalid("SOCKS greeting offered no methods.") }
        guard bytes.count >= 2 + count else { return .needMoreData }
        return .greeting(methods: Array(bytes[2..<2 + count]), bytesConsumed: 2 + count)
    }

    // MARK: Request

    enum RequestResult: Equatable {
        case needMoreData
        /// A protocol error with the reply to send back before closing.
        case rejected(reason: String, reply: Reply)
        case connect(Target, bytesConsumed: Int)
    }

    static func parseRequest(_ bytes: [UInt8]) -> RequestResult {
        // VER CMD RSV ATYP … at least the fixed 4-byte header.
        guard bytes.count >= 4 else { return .needMoreData }
        guard bytes[0] == version else {
            return .rejected(reason: "Unsupported SOCKS version \(bytes[0]).", reply: .generalFailure)
        }
        guard bytes[1] == 0x01 else {
            // 0x02 BIND / 0x03 UDP ASSOCIATE are not supported.
            return .rejected(reason: "SOCKS command \(bytes[1]) is not supported (only CONNECT).",
                             reply: .commandNotSupported)
        }
        let atyp = bytes[3]
        switch atyp {
        case 0x01: // IPv4
            let total = 4 + 4 + 2
            guard bytes.count >= total else { return .needMoreData }
            let host = bytes[4..<8].map(String.init).joined(separator: ".")
            let port = Int(bytes[8]) << 8 | Int(bytes[9])
            return .connect(Target(host: host, port: port), bytesConsumed: total)
        case 0x03: // domain name
            guard bytes.count >= 5 else { return .needMoreData }
            let length = Int(bytes[4])
            let total = 4 + 1 + length + 2
            guard length > 0 else {
                return .rejected(reason: "Empty SOCKS domain name.", reply: .generalFailure)
            }
            guard bytes.count >= total else { return .needMoreData }
            let host = String(decoding: bytes[5..<5 + length], as: UTF8.self)
            let port = Int(bytes[5 + length]) << 8 | Int(bytes[6 + length])
            return .connect(Target(host: host, port: port), bytesConsumed: total)
        case 0x04: // IPv6
            let total = 4 + 16 + 2
            guard bytes.count >= total else { return .needMoreData }
            var groups: [String] = []
            for i in stride(from: 4, to: 20, by: 2) {
                groups.append(String(format: "%02x%02x", bytes[i], bytes[i + 1]))
            }
            let host = groups.joined(separator: ":")
            let port = Int(bytes[20]) << 8 | Int(bytes[21])
            return .connect(Target(host: host, port: port), bytesConsumed: total)
        default:
            return .rejected(reason: "Unsupported SOCKS address type \(atyp).",
                             reply: .addressTypeNotSupported)
        }
    }

    /// Method-selection reply (2 bytes).
    static func methodSelectionReply(accepted: Bool) -> [UInt8] {
        [version, accepted ? methodNoAuth : methodNoneAcceptable]
    }

    /// CONNECT reply (RFC 1928 §6). Ferry always reports a bound address of
    /// 0.0.0.0:0 (ATYP IPv4) — clients don't rely on it for CONNECT.
    static func connectReply(_ reply: Reply) -> [UInt8] {
        [version, reply.rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }
}

/// The SOCKS5 negotiation handler installed on an accepted proxy connection
/// (M14). It drives version/method selection and the CONNECT request with
/// explicit reads (the accepted channel has autoRead off), then hands the
/// decoded target — plus any bytes the client already pipelined after the
/// request — to `TunnelEngine`, which opens the `direct-tcpip` channel, sends
/// the reply, and splices the two channels together.
/// `@unchecked Sendable`: state is confined to the accepted channel's event
/// loop; the conformance only lets the channel initializer capture it.
final class SOCKSServerHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Phase { case greeting, request, done }
    private var phase: Phase = .greeting
    private var buffer: [UInt8] = []

    /// Called once CONNECT is decoded. `leftover` is any post-request bytes the
    /// client already sent (to be replayed onto the SSH channel). The engine
    /// owns the rest of the flow, including sending the success/failure reply.
    private let onConnect: (SOCKSProxy.Target, Channel, ByteBuffer) -> Void

    init(onConnect: @escaping (SOCKSProxy.Target, Channel, ByteBuffer) -> Void) {
        self.onConnect = onConnect
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Once negotiation is done the glue handler sits behind us: pass bytes
        // straight through instead of buffering them.
        guard phase != .done else {
            context.fireChannelRead(data)
            return
        }
        buffer.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        advance(context: context)
    }

    private func advance(context: ChannelHandlerContext) {
        switch phase {
        case .greeting:
            switch SOCKSProxy.parseGreeting(buffer) {
            case .needMoreData:
                context.read()
            case .invalid:
                sendMethodAndClose(context, accepted: false)
            case .greeting(let methods, let consumed):
                buffer.removeFirst(consumed)
                let ok = methods.contains(SOCKSProxy.methodNoAuth)
                write(context, SOCKSProxy.methodSelectionReply(accepted: ok))
                guard ok else { context.close(promise: nil); return }
                phase = .request
                advance(context: context) // any bytes already buffered?
            }
        case .request:
            switch SOCKSProxy.parseRequest(buffer) {
            case .needMoreData:
                context.read()
            case .rejected(_, let reply):
                write(context, SOCKSProxy.connectReply(reply))
                context.close(promise: nil)
            case .connect(let target, let consumed):
                buffer.removeFirst(consumed)
                phase = .done
                let leftover = context.channel.allocator.buffer(bytes: buffer)
                buffer.removeAll()
                onConnect(target, context.channel, leftover)
            }
        case .done:
            // Shouldn't happen (we stop reading after CONNECT), but keep any
            // stray bytes buffered rather than dropping them.
            break
        }
    }

    private func sendMethodAndClose(_ context: ChannelHandlerContext, accepted: Bool) {
        write(context, SOCKSProxy.methodSelectionReply(accepted: accepted))
        context.close(promise: nil)
    }

    private func write(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}
