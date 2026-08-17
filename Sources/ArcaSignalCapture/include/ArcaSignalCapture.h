#ifndef ARCA_SIGNAL_CAPTURE_H
#define ARCA_SIGNAL_CAPTURE_H

/// Makes signals non-fatal and records every delivery on a pipe.
///
/// **This is C rather than Swift because a signal handler may only call
/// async-signal-safe functions, and Swift cannot promise that.** A Swift
/// `@convention(c)` closure compiles to a plain function, but the handler has to
/// reach the descriptor it writes to, and the only way to reach one from a
/// function that captures nothing is a global -- whose access in Swift goes
/// through `swift_once`, which takes a lock. A handler that takes a lock can
/// deadlock against the thread it interrupted. A C file-scope
/// `volatile sig_atomic_t` has no initialiser to run and no lock to take.
///
/// **The pipe is made here and not in Swift for a second reason: this has to be
/// callable before Swift is running at all.** `ArcaSignalCaptureAtLoad` calls it
/// from a `__attribute__((constructor))`, which is the earliest instant any code
/// belonging to this project executes -- earlier than `main`, and therefore
/// earlier than anything a Swift entry point could do. A Swift-owned pipe would
/// have made the whole facility unavailable until the runtime was up, which is
/// exactly the part of startup that was being killed.
///
/// The handler writes one byte per delivery and does nothing else. It does not
/// decide anything, and it does not need to: a byte in a pipe outlives whatever
/// is or is not ready to read it, which is the entire point. Signal handling in
/// this engine is a two-step arrangement for that reason -- capture as early as
/// the process can manage, act whenever the runtime is ready -- and the pipe is
/// what makes the gap between the two steps harmless instead of a window in
/// which signals are lost.
///
/// One capture per process, because a signal disposition is per-process. The
/// pipe is created once and reused; a second call adds signal numbers to it.

/// Creates the capture pipe if it does not exist, and installs a handler for
/// each of `count` signal numbers.
///
/// The write end is non-blocking, because a handler that blocks in `write`
/// blocks whatever thread the signal interrupted; the read end is too, so a
/// spurious readability wake-up cannot park its reader. Both are close-on-exec,
/// so nothing this process spawns inherits either half. A write that fails
/// inside the handler is dropped: the only reachable failure is a full pipe,
/// which means thousands of unread signals are already queued and one more byte
/// says nothing new.
///
/// `SA_RESTART` is set. The disposition being replaced is either the default or
/// `SIG_IGN`, neither of which ever interrupted a system call, so installing a
/// real handler without it would start returning `EINTR` from reads and writes
/// all over a process that never had to expect one.
///
/// Returns 0, or the `errno` of whichever call failed. Safe to call from a
/// library constructor: `pipe`, `fcntl` and `sigaction` are all it does.
int arca_signal_capture_install(const int *numbers, int count);

/// The read end of the capture pipe, or -1 if nothing has installed one.
int arca_signal_capture_read_end(void);

#endif /* ARCA_SIGNAL_CAPTURE_H */
