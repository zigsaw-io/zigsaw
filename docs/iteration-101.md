# Iteration 101: Up and down

Started 2026-11-15, from "plan to implement detached run and `up` / `down`". Since 100, a
project's `zigsaw.json` lists its apps and `zigsaw build` builds them all, but running them
together was left out, with the `run --detach` that needs. `zigsaw run` held its terminal:
a server took a terminal of its own, and a web app with its database took two. Now
**`zigsaw run -d` starts a run in the background, its output in a log that `zigsaw logs`
prints, and `zigsaw up` starts the apps a project lists as `"run"`, each once the one
before serves, and follows their logs until Ctrl+C stops them, as `docker compose up`
does; `zigsaw down` stops them.** zigsaw is **0.101.0**. No recipe or image changes, so
there's nothing to publish. How it's used is in [the README](../README.md#running-in-the-background)
and [its projects](../README.md#a-project-of-several-apps), and the rules are in
[recipes](recipes.md#the-apps-to-run).

State at the start: 100 had landed (`5de2610`, Reproduce 43674640244 and Release v0.100.0
43677229631 green); v0.99.0 was tagged too.

## Outcome

- **`zigsaw run -d` (`--detach`)** prints the number `ps` lists the run by, and returns. A
  zigsaw of its own waits for the app, with no console. The app gets a console with no
  window, NUL on its input, and the run's log on its output and errors. What zigsaw says
  before the app starts, warnings and errors, comes on the terminal `run -d` was typed in;
  an error means nothing started, and exit code 1.
- **The log** is `logs\<app-id>.<run>.log` in the store: a line saying what the run is,
  what the app writes, then what its zigsaw says, `was asked to stop: ...` and
  `ended with exit code N`. It stays after its run, until a detached run of the same app
  starts; `rm` deletes the app's, and `prune` those of apps that aren't installed. One
  that's still written is never deleted.
- **`zigsaw logs [-f] [--tail=<n>] [<app-id>|<run>]`**: a run's log, going or ended; an
  app's, of its detached run going, or else the one that started last. `-f` follows it
  until the run ends. A run that isn't detached, an app with two detached runs going, a
  build and an exec are refused, each saying why.
- **`"run"` in a project's `zigsaw.json`** lists the apps `up` starts, in order: an app's
  id, or an object with `"app"`, `"args"` and `zigsaw run`'s options by name (`"env":
  ["MODE=dev"]`, `"sandbox": "soft"`, `"ephemeral": true`). An app of the project is named
  by its id; another is pinned (`<id>:<version>@sha256:<digest>`) or installed already. A
  `zigsaw.json` with only `"run"` is a project too, of apps from registries.
- **`zigsaw up [-d] [--build] [--yes] [<dir>]`** checks every entry's options as `run`
  would, then builds the project's apps if one it runs isn't installed from its recipe
  (or with `--build`), pulls pinned apps the store hasn't at that digest (asking, unless
  `--yes`), and starts each app as `run -d` does. An app with services is up once each
  answers on its port; only then does the next start. One that ends first, or doesn't
  answer in two minutes, fails `up`, which shows the end of its log and stops what it
  started.
- **`up` then follows their logs**, each line after its app's name (`db  | `, `web | `),
  until they've all ended. Ctrl+C stops them, the last started first, while their last
  lines still print; a second Ctrl+C ends what hasn't stopped. `up -d` returns once
  they're up.
- **A later `up` leaves a run of the project as it is**, and starts it again if the app's
  installed image or its entry changed. A run whose app `"run"` no longer lists is left,
  with a note.
- **`zigsaw down [--time=<s>] [<dir>]`** stops the project's runs: those `"run"` no longer
  lists first, then the rest, the last listed first, an app at a time. With none going it
  says so, and exits 0.
- **`zigsaw logs` with no app or run**, in a project's directory, prints the logs of its
  `"run"` apps, each line after its app.
- **Fixed on the way: a zigsaw with no console of its own died of the Ctrl+C it sent.**
  `stop`'s run zigsaw attaches to the app's console to send Ctrl+C, and left it at once;
  Windows delivers the event to every process on the console a moment later, and one that
  arrives after the zigsaw has left ends it, whatever its handlers say
  (`STATUS_CONTROL_C_EXIT`). It then never cleaned up after the run. A detached run's
  zigsaw always took that path, and a GUI shim's did. It now waits until the Ctrl+C has
  reached it, then leaves.

## Decisions

Yours, by the question dialog:

- **A detached run's output goes to a log file per run, and `zigsaw logs` prints it**, over
  NUL as `exec -d` has. A log stays until the app's next detached run.
- **`up` starts the apps a `"run"` key lists, each with run options**, over every app the
  project lists, or every app no other uses.
- **`up` stays in the terminal**, prefixed logs and Ctrl+C, with `-d` to return, over
  always returning.
- **`up` builds what's missing**, and `--build` builds first, over always or never
  building.
- **`"run"` may name apps from registries by pinned references**, which `up` pulls when
  they're missing, over the project's apps only.

Mine:

- **`"run"` is a list, and its order is the order apps start in.** zigsaw doesn't work out
  one from which app uses which port.
- **Up means its services answer**: something accepts a connection on each service's
  port, on 127.0.0.1 or ::1, within two minutes. Under appcontainer zigsaw itself listens
  on a service's port and relays it into the container, so an answer there means only
  that the run started; the docs say so.
- **An entry's keys are `run`'s option names, and its values go through `run`'s own
  parser** (main.zig's, passed to `up`), so they're checked as `run` checks them, with
  the entry named after the error.
- **What an entry starts is hashed** (its app, options and arguments, 16 hex digits) into
  the run's record with the project's path. That, with the record's manifest, is how a
  later `up` knows a run is still what it would start.
- **A failed start stops what that `up` started**, so `up` either brings the project up or
  leaves it as it was.
- **`down` goes in reverse order, an app at a time**, each with `--time`.
- **The detached child says it started on one pipe for its stdout and stderr**, its last
  line a marker: `exec -d` had two, and read stdout first, so more than 64 KiB of `-v`
  before the start would have kept the child waiting, and warnings were lost when it
  started. `exec -d` moves onto the same code (src/detach.zig); its output stays on NUL.
- **The detached child turns Ctrl+C back on for its app**: Git Bash starts programs with
  Ctrl+C off, processes inherit that, and the app would have ignored the only Ctrl+C it
  gets, `stop`'s.
- **A log is deleted only if nothing writes it**: its writers hold it open to write, and
  sharing writing is what the delete leaves out, so Windows itself refuses while a run
  goes. Two runs of one app starting at once can't delete each other's.
- **A build doesn't read `"run"`**: a typo in a run option never fails `zigsaw build`, or
  an app built alone that finds its project.
- **`up` returns 0 when it stopped the apps, killed or not**, as `stop` does; 1 only when
  something couldn't be ended or didn't start.
- **`ps` is as it was**: the records just have more fields (`log`, `project`, `entry`,
  `ports`), which older zigsaws ignore.
- **A run `up` would start is warned about if the same app has a run going that the
  project didn't start**: its port may be taken, or answer for the new one.

## Probe

Done as slice 1 itself, with `run -d` in each sandbox (`E:\zs\i101\probe1.sh`,
`waiter-exit.ps1`):

- **A low or AppContainer app writes the log** through the handle it inherits, which it
  couldn't open by name.
- **`stop` reaches a detached console app** by attaching to its console, which
  CREATE_NO_WINDOW gives it, under soft, low and appcontainer.
- **The app ignored that Ctrl+C when `run -d` was typed in Git Bash**, as it turns Ctrl+C
  off for what it starts. Fixed as above.
- **The waiter then died of its own Ctrl+C**: exit code 0xC000013A, no end line in the
  log, and no cleanup. A handler it registered after attaching was never called. With the
  console kept until its handler has seen the event, it survives in all three sandboxes.

## Files

- `src/detach.zig` (new): the detached child's start, its marker, `tellStarted`.
- `src/logs.zig` (new): log paths and names, `create`, `deleteEnded`, `newestOf`,
  `zigsaw logs`, the `Follower`, `prefixes`; unit tests for names, prefixes and lines.
- `src/up.zig` (new): `up`, `down`, `logs` in a project; readiness, restarts, roll back,
  Ctrl+C on a thread of its own.
- `src/run.zig`: `--detach`, the detached child (log, NUL, CREATE_NO_WINDOW, Ctrl+C on,
  marker, end line), the record's new fields, `startDetached`, `servedPorts`.
- `src/compose.zig`: `"run"` allowed, projects of only `"run"`, `RunEntry`, `runList`;
  unit tests.
- `src/stop.zig`: `end` (what `stop`, `down` and `up` share), `Options.pids` and
  `.cancel`, the console kept until the Ctrl+C reaches its sender.
- `src/exec.zig`: `exec -d` on detach.zig. `src/ps.zig`: the record's fields.
  `src/prune.zig` and `rm`: logs. `src/win32.zig`: a few declarations.
  `src/main.zig`: the options and commands, their usage.
- `tests/up.sh` (new), a step for it in `.github/workflows/reproduce.yml`;
  `tests/ctrlc.zig`: `term` presses Ctrl+C once each text it's given shows.
- README, `docs/recipes.md`, `docs/testing.md`; 0.101.0 in `build.zig.zon` and
  `zigsaw.json`.

## Results

| what | result |
|---|---|
| unit tests | all pass; new in `src/compose.zig` (the run list, a project of only `"run"`) and `src/logs.zig` (names, prefixes, lines) |
| `tests/up.sh` | 91 ok, 0 failed, three times: on the build the suites below ran with (30 s), and twice on 0.101.0, the last on the final build (26-31 s) |
| `tests/exec.sh` | 56 ok, twice (on the final build too): `exec -d` on the shared detach code |
| `tests/stop.sh`, `ps.sh`, `limits.sh`, `ctrlc.sh`, `sandbox.sh`, `volumes.sh` | 48, 44, 68, 28, 142 and 135 ok; 0 failed |
| `tests/build.sh`, base group | 131 ok, 0 failed (76 s), `apps` among them |
| by hand | `run -d` and `stop` in each sandbox, the waiter's exit code read through a handle (`E:\zs\i101\waiter-exit.ps1`): 0xC000013A before the fix, the app's after |
| the package | zip `42d17a9f`, 0.101.0; Defender finds nothing in its six programs |

Between those runs and the final build, only the usage text, the messages `up`, `down`
and `logs` give outside a project, the version, and `zig fmt` of `src/compose.zig`
changed; `up.sh` ran again after all of them, `exec.sh` after all but the last.

Defender quarantined one build along the way, as Zig's build runner wrote it
(`Behavior:Win32/DefenseEvasion.A!ml`, on `zig-out\bin\zigsaw.exe`). The builds after it,
with more code, weren't flagged, nor is the package. Nothing was restored or excluded.

## Not checked

- **A real pair**, PostgreSQL from ghcr.io and an app that uses it: only BusyBox and the
  network probe.
- **A GUI app detached**, and whether a console app's hidden console flashes a window:
  none was seen, but nobody watched the desktop for it.
- **A standard user**, `tests/matrix.sh` and the GUI suites.

## Not this time

- Log rotation, or a size cap: a server's log grows until its app's next detached run.
- `exec -d`'s output in the run's log.
- Restart policies, health checks other than ports, and a wait per app.
- An order worked out from which app uses which service.
- Starting apps that don't wait for each other at once.
- Several runs of one app (compose's `--scale`), and full registry references
  (`ghcr.io/owner/app@sha256:...`) in `"run"`.
- Coloured prefixes, and a project filter for `ps`.

## Yours to do

- Commit and push (`src/detach.zig`, `src/logs.zig`, `src/up.zig`, `tests/up.sh` and this
  file are new). I read the Reproduce run, `tests/up.sh` first.
- The tag `v0.101.0` is yours; I read the Release run after it.
