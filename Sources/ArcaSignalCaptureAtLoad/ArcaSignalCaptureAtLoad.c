#include "ArcaSignalCaptureAtLoad.h"

#include "ArcaSignalCapture.h"

#include <signal.h>

/// -1 until the constructor runs, which is how a build that failed to link it
/// is told apart from one where the install itself failed.
static int arca_at_load_result = -1;

/// The signals a supervisor or an operator stops this engine with. `SIGINT` is
/// here as well as `SIGTERM` because a foreground engine is stopped with `^C`
/// and must take the same path.
static const int arca_at_load_signals[] = {SIGTERM, SIGINT};

__attribute__((constructor)) static void arca_signal_capture_at_load(void) {
    arca_at_load_result = arca_signal_capture_install(
        arca_at_load_signals,
        (int)(sizeof(arca_at_load_signals) / sizeof(arca_at_load_signals[0]))
    );
}

int arca_signal_capture_at_load_result(void) {
    return arca_at_load_result;
}
