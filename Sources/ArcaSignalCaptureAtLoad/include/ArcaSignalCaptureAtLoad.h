#ifndef ARCA_SIGNAL_CAPTURE_AT_LOAD_H
#define ARCA_SIGNAL_CAPTURE_AT_LOAD_H

/// Takes charge of `SIGTERM` and `SIGINT` from a `dyld` initialiser, which is
/// the earliest instant code belonging to this project runs.
///
/// **This is a separate target from `ArcaSignalCapture` because a load-time side
/// effect must not follow the library everywhere it is linked.** `ArcaEngine`
/// links the plain capture target, and `ArcaEngine` is linked by the test
/// bundle; a constructor there would install `SIGTERM` handlers inside `xctest`
/// and quietly make the test runner unkillable by the ordinary signal. Only the
/// `arca-engine` executable -- the process that must survive being signalled
/// during its own startup -- links this one.
///
/// **How early this actually is, MEASURED rather than assumed -- and it is less
/// of a gain than it sounds.** A process cannot protect the part of its startup
/// that runs before its first instruction, and for a Swift binary linking 40
/// libraries that part is `dyld` mapping and binding them, which happens before
/// any initialiser, this one included. Spawning `arca-engine` and signalling it
/// after a delay, six engines per delay, warm: with capture in the Swift entry
/// point every engine was killed at 0, 1, 2 and 5ms and every engine survived
/// from 20ms; from this constructor, killed at 0, 1, 2 and 5ms and surviving
/// from 10ms. Timestamping this function against its parent's clock puts it
/// **10-13ms after the spawn returns**, and the whole of that is `dyld`.
///
/// So what the constructor buys is the interval between `dyld` finishing and
/// `EngineEntryPoint.main` -- the Swift runtime's start-up and ArgumentParser --
/// and not the interval that dominates. It is kept because it is the earliest an
/// in-process capture can be and costs one object file, and because the residue
/// it leaves is now documented rather than waiting to be discovered: closing
/// that needs the LAUNCHER to block the signal before `exec`, which
/// `arca_signal_capture_install`'s unblock is the far end of.

/// The result of the load-time install: 0 if it succeeded, an `errno` if it
/// failed, and -1 if the constructor never ran at all.
///
/// **Reading it is not optional, and not only because the answer matters.** The
/// constructor lives in an object file nothing else references, and a static
/// library's unreferenced objects are not linked in; calling this from the
/// executable is what makes the constructor part of the binary. A version that
/// installed and never checked would have silently linked nothing.
int arca_signal_capture_at_load_result(void);

#endif /* ARCA_SIGNAL_CAPTURE_AT_LOAD_H */
