#include "ArcaSignalCapture.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

/// Where the handler writes. `volatile sig_atomic_t` is the only type a handler
/// may read that the standard promises is coherent, and it has no initialiser to
/// run: reaching it takes no lock and can therefore never deadlock against the
/// thread the signal interrupted.
static volatile sig_atomic_t arca_capture_write_end = -1;

/// The other half. Read by `arca_signal_capture_read_end`, never by a handler.
static int arca_capture_read_end = -1;

/// One byte, and nothing else.
///
/// `errno` is saved and restored because the handler runs on whichever thread
/// the kernel picked, in the middle of whatever that thread was doing. A failing
/// `write` here that left `EAGAIN` behind would be read by the interrupted code
/// as the result of *its* system call.
static void arca_signal_handler(int number) {
    int saved = errno;
    int descriptor = (int)arca_capture_write_end;
    if (descriptor >= 0) {
        unsigned char byte = (unsigned char)number;
        // Deliberately unchecked; see the header on why a failed write is
        // nothing this process can act on from inside a signal handler.
        ssize_t ignored = write(descriptor, &byte, 1);
        (void)ignored;
    }
    errno = saved;
}

/// Non-blocking and close-on-exec, or the `errno` that stopped it.
static int arca_configure(int descriptor) {
    if (fcntl(descriptor, F_SETFL, O_NONBLOCK) != 0) {
        return errno;
    }
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
        return errno;
    }
    return 0;
}

int arca_signal_capture_install(const int *numbers, int count) {
    if (arca_capture_read_end < 0) {
        int ends[2];
        if (pipe(ends) != 0) {
            return errno;
        }
        for (int i = 0; i < 2; i++) {
            int failure = arca_configure(ends[i]);
            if (failure != 0) {
                close(ends[0]);
                close(ends[1]);
                return failure;
            }
        }
        arca_capture_read_end = ends[0];
        arca_capture_write_end = (sig_atomic_t)ends[1];
    }

    sigset_t captured;
    sigemptyset(&captured);

    for (int i = 0; i < count; i++) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = arca_signal_handler;
        // Every signal blocked for the duration, so a second signal cannot
        // re-enter the handler while the first is inside `write`.
        sigfillset(&action.sa_mask);
        action.sa_flags = SA_RESTART;

        if (sigaction(numbers[i], &action, NULL) != 0) {
            return errno;
        }
        sigaddset(&captured, numbers[i]);
    }

    // **Unblocked, because a signal mask is inherited across `exec` and this
    // process does not choose the one it starts with.** A parent that spawned
    // it with `SIGTERM` blocked would leave an engine that installs a perfectly
    // good handler and never hears a thing -- unkillable by the ordinary
    // signal, which is the failure this whole facility exists to prevent.
    //
    // It is also the far end of the only mechanism that closes the window
    // before this constructor runs. Nothing inside a process can protect the
    // milliseconds `dyld` spends mapping and binding it -- MEASURED at 10-13ms
    // from spawn to this function -- but a launcher that blocks these signals
    // before `exec` turns anything arriving in that window into a PENDING
    // signal rather than a dead process, and this line is what then delivers
    // it: pending becomes delivered the moment the mask drops, the handler
    // queues it, and the engine acts on it as soon as it has an action. A
    // launcher that does nothing is unaffected, because unblocking what is not
    // blocked is a no-op.
    if (sigprocmask(SIG_UNBLOCK, &captured, NULL) != 0) {
        return errno;
    }
    return 0;
}

int arca_signal_capture_read_end(void) {
    return arca_capture_read_end;
}
