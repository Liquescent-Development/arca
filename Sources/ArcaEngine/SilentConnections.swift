import NIOCore

/// Closes an accepted connection that has exchanged nothing, at the moment the
/// server is asked to quiesce.
///
/// **Without this, one connection that has been accepted and has not yet spoken
/// costs the engine its whole ten-second grace and then its exit status.**
/// `ServerQuiescingHelper` counts an accepted channel from the instant it is
/// accepted and waits for it to close. It closes by being asked to quiesce --
/// grpc-swift turns `ChannelShouldQuiesceEvent` into a GOAWAY and closes the
/// connection once its streams finish -- but only for a connection whose
/// protocol has been negotiated. One that has been accepted and has sent nothing
/// is in no protocol at all: `GRPCServerPipelineConfigurator` is the only
/// handler in its pipeline, and that handler acts on `TLSUserEvent` and forwards
/// every other event untouched. Nothing closes it, and the drain waits for as
/// long as the peer cares to hold the socket.
///
/// **MEASURED, against Arca `218343b` and Gas Can's live tier, and this is the
/// first time the grace has been observed to fire against anything.** A raw
/// `UnixStream` connected to the engine, left silent and held across the signal,
/// made the engine exit `1` after **10.01s** with `connections did not drain
/// within the grace period; closing anyway` -- and the same test WITHOUT the
/// pause that lets the accept happen exited `0` after **0.01s**, which is the
/// control: an unaccepted connection holds nothing.
///
/// **It is not a hypothetical peer, it is Gas Can's own client, and it is the
/// defect this type was written for.** Stopping 1324 engines each holding an
/// ordinary `tonic` channel gave `1323 x exit status: 0, 1 x exit status: 1`,
/// slowest shutdown **10.01s**, and the one unclean engine logged that same
/// grace-period line. A client that connects and loses a microsecond race
/// against the signal -- its HTTP/2 preface written but not yet read by the
/// server -- is in exactly the state above.
///
/// **Closing such a connection loses nothing, and that is what makes this safe
/// rather than a shortcut.** No protocol has been negotiated, so no stream can
/// exist, so no RPC can be in flight; there is nothing to drain. The peer sees a
/// closed connection immediately instead of ten seconds later, which is what it
/// was going to get either way.
///
/// **The predicate is "has this channel ever delivered an inbound read", and it
/// is exact rather than a heuristic.** `GRPCServerPipelineConfigurator` buffers
/// what it reads and deliberately does not forward it -- "Don't forward the
/// reads: we'll do so when we have configured the pipeline" -- and forwards the
/// buffer only from `removeHandler`, which runs when it has configured the
/// pipeline and is taking itself out. This handler is installed after it, so a
/// read arriving here IS the configuration having happened, and no read having
/// arrived here IS the pipeline still being unconfigured.
final class SilentConnectionQuiescer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// Whether anything has ever been read on this channel. See the type's note
    /// on why this is the exact negotiation predicate and not a proxy for one.
    ///
    /// Unsynchronised on purpose: a `ChannelHandler` is only ever invoked on its
    /// own channel's event loop, and both readers of this are handler callbacks.
    private var spoke = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        spoke = true
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Forwarded either way. A quiesce is not this handler's to consume: the
        // handlers after it are the ones that turn it into a GOAWAY, and
        // swallowing it would break the drain for every connection that CAN
        // drain in order to fix the one that cannot.
        context.fireUserInboundEventTriggered(event)

        guard event is ChannelShouldQuiesceEvent, !spoke else { return }
        context.close(promise: nil)
    }
}
