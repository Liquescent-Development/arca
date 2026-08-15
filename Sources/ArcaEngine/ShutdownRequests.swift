import NIOConcurrencyHelpers

/// Counts shutdown signals, and answers whether any has arrived.
///
/// **Locked rather than queue-confined, and it used to be the latter.** Both of
/// `arca-engine`'s signal sources still share one serial queue, but the engine
/// also reads this from a `whenComplete` on the listening channel's close, which
/// runs on a NIO event loop. Two threads, so the confinement argument no longer
/// holds and a lock replaces it rather than a comment claiming a discipline the
/// code no longer keeps.
///
/// **It lives in this module rather than beside its one caller so that a test
/// can drive the real type.** It was `private` in the executable, where nothing
/// can reach it: a review probe for the shutdown observer had to re-declare it,
/// and a test that drives a re-declaration proves the re-declaration -- the
/// shape this project has shipped and caught before. `ShutdownObserverTests`
/// now exercises this one.
public final class ShutdownRequests: Sendable {
    private let seen = NIOLockedValueBox(0)

    public init() {}

    /// Records a request and answers whether it was the first.
    ///
    /// The increment and the comparison are one critical section, so two
    /// signals arriving together cannot both be told they were first.
    public func recordAndReportFirst() -> Bool {
        seen.withLockedValue { seen in
            seen += 1
            return seen == 1
        }
    }

    /// Whether any signal has been recorded.
    ///
    /// Read to tell a listening socket that closed BECAUSE of a shutdown from
    /// one that closed on its own. A separate acquire is all this needs: the
    /// predicate is monotone, and a read that races the very first increment
    /// resolves to "not yet", which errs toward treating a shutdown that has
    /// just begun as an unexpected close -- both end the process.
    public var anyRecorded: Bool { seen.withLockedValue { $0 > 0 } }
}
