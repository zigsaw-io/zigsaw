# Iteration 98: Asked to stop

Started 2026-11-13, from "plan to implement stop & kill". Since 97, `zigsaw ps` could list the
runs and builds going in a store, but nothing could end one but Task Manager or `taskkill`, and
both kill the run's zigsaw with its app. A zigsaw killed that way can't take the app's keys back
from HKCU, delete an `--ephemeral` run's data, or end its record: the next run, `repair` or
`ps` settles that. Now **`zigsaw stop` asks a run or build to end, and ends what hasn't after
`--time`; `zigsaw kill` ends it now. Either way the run's own zigsaw cleans up after it.**
zigsaw is **0.98.0**. No recipe or image changes, so there's nothing to publish. How it's used
is in [the README](../README.md#stopping-a-run).

State at the start: 97 had landed (`58b3f71`, Reproduce 43398030333 and Release 43406753925
green).

## Outcome

- **`zigsaw stop [--time=<seconds>] <app-id>|<run>...`** takes what `ps` takes. It asks each run
  to end, waits for all of them at once, 10 seconds unless `--time` says otherwise, then ends
  what's left. It prints a line for each: `stopped 4812 (org.x)`, `killed 4812 (org.x) after
  10 s`, or why it couldn't.
- **`zigsaw kill <app-id>|<run>...`** ends them now: a run by its job, with exit code 1, as
  `taskkill /F` gives; a build by its zigsaw.
- **Asking** is done by the run's own zigsaw, which `stop` wakes through a named event in the
  record (`stop`). The run's zigsaw posts WM_CLOSE to the app's visible top-level windows (not
  a console's own, which would close the console) and sends Ctrl+C to its console, when the
  rule below allows it. It says on its console what it did: `zigsaw: org.x was asked to stop:
  asked its window to close, and sent Ctrl+C to its console`.
- **Ending a run by its job**, not its zigsaw: the zigsaw sees its app end and cleans up as
  after any run. An `--ephemeral` run's data is gone once `kill` returns, and the record too.
- **Runs inside the one ended end first**, innermost first, so each inner zigsaw cleans up too,
  rather than being ended with the outer job. `kill` lists them as `(in run <n>)`.
- **A build** that is asked fails at its next command, or during one if Ctrl+C ends it:
  `module m: stopped by `zigsaw stop` during build command 2`. Killed, its zigsaw ends with
  the command's tree. Either way its kept build root is there for the next build to go on from.
- **A zigsaw with no console** (one a GUI shim started) attaches to the app's console, if it got
  one of its own, to send it Ctrl+C.

### When Ctrl+C is sent

Windows sends Ctrl+C to everything on a console, as the key does; it can't be aimed at one
program. So the run's zigsaw sends it only when:

- some process of the run is on its console,
- every other process there is the zigsaw itself or what started it (its shell, which takes it
  as if Ctrl+C had been pressed there),
- and the `zigsaw stop` isn't there: `stop` writes its PID to `running\<pid>.stopping` before it
  sets the event.

Otherwise it says what was in the way (`didn't send Ctrl+C: PING.EXE (5120) is on its console
too, and isn't the run's`), and the run is ended after `--time`.

## Decisions

Yours, by the question dialogs:

- **A guarded Ctrl+C**, over sending it as the key does or not at all.
- **Runs and builds.**
- **Not from the run's own console**, after the probe: you first chose to let Ctrl+C reach the
  `zigsaw stop` and what started it as well. The probe showed a Git Bash script dies outright
  of Ctrl+C while it waits on a native program, which is just what a script running `zigsaw
  stop` does; a batch file would be asked "Terminate batch job (Y/N)?" and PowerShell would
  stop. So a `stop` typed in the run's own terminal sends none, and says so.

Mine:

- **The run's zigsaw asks; the stopper ends.** Only the run's zigsaw shares the app's console
  and holds the job, and it ignores Ctrl+C already. `stop` holds the time and the ending, so a
  run's zigsaw that hangs is still ended.
- **An event, named like the job** (`Local\zigsaw.<pid>.<16 hex>.stop`), with the same
  reasoning as 97's job names: the random part keeps anyone from making it first, low and
  AppContainer runs can't open it, and a soft run could already end its own app.
- **A build is ended by its zigsaw**, not its command's job. Between commands, while it
  downloads or packs, there's no job to end. A killed build leaves the build drive mapped
  until the next build replaces it, as a crashed one does.
- **A run whose record has no `stop` event** (its zigsaw is older than 0.98, or couldn't make
  one) is killed at once, rather than after `--time`: waiting would change nothing. The plan
  said after `--time`.
- **`process.Child.stop` is a function pointer**, not stop.zig's type: the shims, zigsaw-host and
  zigsaw-notify wait there too, and don't carry `ps` and the store.
- **Only the first signal asks.** A second `zigsaw stop` sets the event again, which changes
  nothing; it waits and kills as the first does.

## Probe

Done first, on the real code path (`E:\zs\i98`):

- **The Bash tool's console** holds only its own bash processes, not Claude Code's: checked
  before any Ctrl+C was sent.
- **Under MSYS the Windows parent chain breaks**: after an MSYS program execs another
  (`timeout` → `bash`), the process that made the new one has ended, so the chain from a run's
  zigsaw stops short of the shells above. A Git Bash script's runs mostly get no Ctrl+C; the
  guard takes the safe side.
- **A Git Bash script dies of Ctrl+C** while it waits on a native program (above).
- **In a terminal of its own** (a pseudoconsole, as Windows Terminal and VS Code host programs),
  Ctrl+C reached BusyBox under soft, low and appcontainer, which ended at once (130).
- **WM_CLOSE** from a medium zigsaw reached a window in each sandbox (a probe window run from a
  granted folder through BusyBox's sh); it closed itself, and the run ended 0.
- **A zigsaw with no console** (started DETACHED, as a GUI shim starts it) attached to the app's
  own console and sent Ctrl+C, which ended it. Git Bash starts native programs with Ctrl+C
  off, and they inherit that; the probe's launcher turns it back on, as Explorer never turns
  it off.

## Files

- `src/stop.zig` (new): `Asker` (the event, asking, the note), the console guard, `ancestors`,
  the commands; unit tests for the guard, the window filter, `ancestors`, `describe`.
- `src/process.zig`: `Stop`, `Child.stop`, `Report.stopped`; the wait covers the event.
- `src/ps.zig`: `Record.stop`, `.stopping` files, `jobPids`, `nest`, `depthOf`, `within`.
- `src/run.zig`, `src/builder.zig`: the event, the record's `stop`, a build's checks.
- `src/win32.zig`: consoles, windows, ending jobs.
- `src/main.zig`: the commands, their usage.
- `tests/ctrlc.zig`: `zigsaw-ctrlc term <command line>`, a command in a pseudoconsole of its own.
- `tests/stop.sh` (new), a step for it in `.github/workflows/reproduce.yml`; README.

## Results

| what | result |
|---|---|
| unit tests | all pass; new in `src/stop.zig` (the guard, the window filter, `ancestors`, `describe`) and `src/ps.zig` (`depthOf`, `within`) |
| `tests/stop.sh` | 48 ok, twice: 27 s and 23 s |
| `tests/ps.sh`, `limits.sh`, `sandbox.sh`, `volumes.sh`, `ctrlc.sh`, `build.sh` (base) | 44, 68, 142, 135, 28 and 113 ok; 0 failed |
| the package | zip `fc5081b8`, 0.98.0; Defender finds nothing in its six programs |

## Not checked

- **A standard user**, `tests/matrix.sh`, the GUI suites and the other `build.sh` groups.
- **Closing windows in a suite**: WM_CLOSE was probed by hand only, as a suite's window would
  open on the screen of whoever runs it.
- **A real GUI app** (an Electron or Qt one, whose closing may ask about unsaved work): such
  an app is killed after `--time` if it waits on its question.

## Yours to do

- Commit and push (`src/stop.zig`, `tests/stop.sh` and this file are new). I read the
  Reproduce run, `tests/stop.sh` first.
- The tag `v0.98.0` is yours; I read the Release run after it.
