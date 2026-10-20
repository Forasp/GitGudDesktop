# Profiling

GitGud measures where its time goes on every thread. Nothing has to be
rebuilt for the usual case: the zones and the stall watchdog are in every
build, and cost almost nothing until a capture runs.

## Stall watchdog (always on)

When one pass of the main loop keeps the UI thread busy for longer than
200 ms, the watchdog samples it every 50 ms until it lets go, then appends
a report to `logs/perf.log` in the app's data folder
(`%APPDATA%\Gitgud\logs\perf.log` on Windows). A report has:

- how long the UI thread was blocked;
- the zones open when it started (the main loop's phase, the Lua handler or
  timer, and the C++ zones under it), and how often each set of zones held
  over the stall;
- Lua tracebacks taken while it ran Lua;
- the native stack at the first sample, the innermost functions of all
  samples, and the functions on the stack in most samples (Windows).

A stall that lasts more than 2 s is written while it lasts too (every
10 s), so a freeze that ends in a kill still leaves its record. The log
also gets the process's memory every five minutes, with the main window's
frames since the last such line: how many were presented, how many of those
failed to present, and how long ago the last one was.

## A window that stops showing what's drawn

A window can look frozen while the UI thread is fine: input, layout and
drawing all go on, but no frame reaches the screen (seen after a monitor on
a dock came back). The watchdog has nothing to report then; the frame counts
on the memory lines keep going, and `[display]` lines in the app's output
say when the displays changed and when presenting a frame failed.

The app renews the main window when the displays change
(`resources/scripts/core/display.lua`, after the changes settle for 1.5 s):
a new window in the old one's place, the same OpenGL context made current
on it, so the UI comes back as it was. **Ctrl+Alt+Shift+R** does the same by
hand, in any interface, and scripts can ask with
`gitgud.emit("window.renew", why)`.

`GITGUD_STALL_MS=<ms>` changes the threshold (0 turns the reports off);
scripts can read and set it with `gitgud.stallThreshold([ms])`.

## Captures

A capture records every zone on every thread: C++ zones, every Lua function
and every C function Lua calls (through a call hook), each event handler
and timer by the event and the line it's defined on, and the main loop's
phases, plus memory once a second. Start and stop one with:

- **Ctrl+Alt+Shift+P**, in any interface;
- `gitgud.profileStart()`, `gitgud.profileStop()`, `gitgud.profileToggle()`
  from a script (`gitgud.profiling()` returns whether one runs, its seconds
  so far, and the last report's folder);
- `GITGUD_PROFILE=1` to capture from launch (`GITGUD_PROFILE=zones` leaves
  the Lua call hook out, for timings closest to a normal run), with
  `GITGUD_PROFILE_SECONDS=<n>` to stop after n seconds.

When it stops, the reports are written on a worker thread into
`logs/profile-<date>-<time>/`, and the app publishes `profiler.saved` with
that folder:

| File          | What it is                                                     |
|---------------|----------------------------------------------------------------|
| `report.txt`  | UI frame times (median, p95, p99, max, counts over 16.7, 50, 200 ms and 1 s, the waits for input and for the display left out); the 20 slowest frames, each split into self time per zone; per thread, every zone's inclusive and self time, calls, average and longest; callers and callees of the 15 zones with the most self time; memory over the capture |
| `flame.svg`   | A flame graph per thread; open it in a browser, click a frame to zoom, Escape to zoom out. Orange is C++, green Lua, blue Lua calling C |
| `trace.json`  | The timeline in Chrome's trace format: open it at ui.perfetto.dev or chrome://tracing (at most two million events, the longest) |
| `folded.txt`  | Folded stacks with self time in microseconds, for other flame graph tools |

Inclusive time counts a recursive zone once. With the Lua call hook on,
Lua runs slower than normal (each call and return goes through the hook),
so compare Lua-heavy numbers between captures made the same way.

## Zones in C++

```cpp
#include "app/Profiler.h"

void Repository::Status()
{
    GITGUD_PROFILE_FUNCTION();          // named after the function
    ...
    {
        GITGUD_PROFILE_SCOPE("diff the index");
        ...
    }
}
```

Name a worker thread with `gitgud::prof::SetThreadName("...")` so its
zones show under that name. TaskRunner jobs are zones of their own
("task <name>").

## Every C++ function

Configure with `-DGITGUD_PROFILE_INSTRUMENT=ON` to make every function of
the app's own code a zone (MSVC `/Gh /GH`, GCC and Clang
`-finstrument-functions`). Names come from the program's symbols when the
report is written. This build is much slower and for profiling only; keep
its captures short.

## A scripted heavy session

`tests/ui/perf-bragi.lua` drives the Bragi interface through heavy use:
it opens the saved conversations named in `PERF_IDS`, switches between
them, streams long replies into three conversations at once and the shown
one, and hot-reloads with all of them open, printing
`[perf-step] <step> <ms>` for each. Run it like the other Bragi scripts
(scratch `APPDATA`, `LOCALAPPDATA` and `CLAUDE_CONFIG_DIR`, the build's
`gitgud_test_claude.exe`), with `GITGUD_PROFILE=1`, against a copy of real
transcripts to see real sizes.

`tests/ui/perf-reads.lua` times how Bragi's own conversation reads saved
transcripts: its check that its saved session is still there, a recap of
the conversations it follows, and reading one back, each first from the
files and then cached. Run it the same way, on a copy of real data that has
a master conversation and followed ones.
