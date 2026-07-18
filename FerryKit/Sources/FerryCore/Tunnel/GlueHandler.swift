import NIOCore

/// Splices two NIO channels together so bytes read on one are written to the
/// other and vice-versa — the workhorse of a port forward (M14, ADR-021).
///
/// A matched pair is created with `matchedPair()`; one handler goes on the
/// accepted local connection, the other on the SSH `direct-tcpip` channel. It
/// propagates:
///
/// - **Data** both directions (as opaque `NIOAny`, so it works for the raw
///   `ByteBuffer`s both channels carry).
/// - **Backpressure**: a side only issues `read()` when its partner is
///   writable, otherwise the read is parked until the partner drains.
/// - **Half-closure**: an input-closed event on one side closes the partner's
///   output, so a peer that shuts down writing (e.g. HTTP with `Connection:
///   close`) is mirrored rather than dropped.
/// - **Teardown**: either channel going inactive, or any error, tears down the
///   partner.
///
/// The two handlers touch each other's `ChannelHandlerContext` directly, so a
/// pair **must** live on the same `EventLoop`. `TunnelEngine` guarantees this
/// by running its SSH client and its local listener on one dedicated
/// single-thread group. This is the canonical swift-nio glue pattern.
///
/// `@unchecked Sendable`: all mutable state is confined to that one event loop;
/// the conformance only exists so a handler can be captured by the channel
/// initializer closures that install it (never to move it across threads).
final class GlueHandler: @unchecked Sendable {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // Peer stopped writing: mirror the half-close to the other side's
            // output instead of tearing the whole tunnel down.
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
