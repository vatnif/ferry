import NIOCore
import NIOSSH

/// Translates the raw `SSHChannelData` a `forwarded-tcpip` child channel
/// carries into plain `ByteBuffer`s (and back) so a `GlueHandler` pair can
/// splice it to a local TCP connection. Citadel installs its equivalent codec
/// on `direct-tcpip` channels itself, but hands `forwarded-tcpip` channels
/// over raw — and keeps its codec internal — so Ferry carries this copy
/// (M14.5, ADR-022).
final class SSHChannelDataCodec: ChannelDuplexHandler, Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    struct UnexpectedSSHData: Error {}

    func handlerAdded(context: ChannelHandlerContext) {
        // GlueHandler mirrors half-closure; the channel must surface it.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { context.fireErrorCaught($0) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let bytes) = data.data else {
            context.fireErrorCaught(UnexpectedSSHData())
            return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}
