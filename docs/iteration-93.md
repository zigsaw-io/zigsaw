# Iteration 93: What a run may use

Started 2026-11-12, from "plan to implement Job Objects resource limiter". Every run, and every
command of a build, has been in a job object since iteration 1, and the job did one thing: end
the process tree. Nothing said how much a tree may use. That has cost time: Rnote's 16 rustc
processes ran this machine out of memory in iteration 60, LLVM's links did the same, and the
answer each time was a number in a recipe. Now `--memory` and `--cpus` hold a run, an app's every
run, or a build's commands to an amount of memory and a number of processors. zigsaw is
**0.93.0**. No image changes, so there's nothing to publish. How it's used is in
[the README](../README.md#limits), how it works in [how-it-works.md](how-it-works.md).

State at the start: 92 had landed (`5cb5933`, Reproduce 43162458434 green).

## Outcome

- **`zigsaw run --memory=<size> --cpus=<n>`** holds the app and everything it starts. Both are
  run options like the others: `zigsaw override` saves them for an app or, with `--global`, for
  every app of the store, shims get them, and the command line goes over what's saved.
  `--memory=none` and `--cpus=all` take a saved one away.
- **`zigsaw build --memory=<size> --cpus=<n>`** holds each of the build's commands, vendor steps
  too. They are no input of the build: the image is the same, and no recipe changed.
- **Past the memory limit Windows refuses the tree more**, and the program fails as it does when
  a machine runs out. zigsaw then names the limit: after the run (through a GUI shim, in the box
  a failed run shows), or after the build's command, before the line that says it failed.
- **`--cpus=N` is N processors on N cores**, where the machine has them: one of each core before
  a second of any. On this machine that is 4.9 s for four busy processes against 9.2 s on the
  first four logical processors, which are two cores.
- **Programs are told three ways**, as none of them reaches every program: the job's affinity
  (Go, Node, BusyBox's `nproc` count by it), a CPU rate cap of the same share (Ninja counts by
  it), and `NUMBER_OF_PROCESSORS` and `CARGO_BUILD_JOBS` in the environment (cargo counts the
  machine's processors whatever the job says). zig and CMake's own count heed none of them.
- **`-v` prints the most memory a run had**, and each build command that takes a second or more:
  a number to pick a limit from.

## Decisions

Yours, by the question dialogs:

- **Runs and builds**, over one of them.
- **Memory and CPU**, not a process count or a lower priority.
- **`--cpus=N` means N processors visible** (affinity), over a share of processor time as
  Docker's `--cpus=1.5`.
- **Yours to set only**: command line, overrides, build options. Nothing in recipes or image
  configs.
- **Both variables** (`NUMBER_OF_PROCESSORS` and `CARGO_BUILD_JOBS`), asked after the probe
  showed cargo counts 16 processors under every kind of job limit.

Mine:

- **The affinity and a matching CPU rate cap together.** I told you at the first question that
  tools like cargo, Ninja and make would start N jobs under an affinity by themselves. The probe
  said otherwise for two of the three: Ninja reads the job's CPU rate and nothing else, and
  cargo reads neither. The cap is the same share the affinity already holds the job to, measured
  as costing nothing (8.4 to 9.2 s with, 8.2 to 9.4 s without), and rounded up so that Ninja's
  arithmetic gives N.
- **One processor per core first**, the faster cores first. The lowest N bits of the mask, which
  the plan had, are N/2 cores on a machine with two processors per core.
- **Among zigsaw's own processors only**, so the mask is always within an outer job's (a CI
  runner's, a terminal's). As many as zigsaw has, or more, is no limit, sets no cap and no
  variable.
- **The variables go in before the app's own**, the runtimes', the module's and `--env`, so
  whatever sets them already wins. Rnote's recipe keeps its `CARGO_BUILD_JOBS=8`.
- **A completion port only for a job with a memory limit**, emptied four times a second while
  zigsaw waits. A job tells its port of every process that starts and ends; left unread through
  a long build those would pile up in the kernel. A run without `--memory` waits exactly as
  before.
- **Told by the port or by the peak.** Windows doesn't promise the port every message. The job's
  peak commit counts what was refused, so a peak at or over the limit says the same.
- **0 isn't a limit**: `--memory=0` and `--cpus=0` are refused, and the words `none` and `all`
  say it. In an overrides file they are saved as 0, under the same names.
- **Sizes print as they are typed**: `--memory=1536MB` shows as that in `override --show`, in the
  largest unit that takes no fraction.

Deviations from the plan: the rate cap, the choice of processors and the two variables above,
all from the probe. The plan had zigsaw explain a process that can't start under a limit too
small to load it; there is no such case (a process starts under 1 MiB and fails at its first
allocation), so nothing was built for it. The plan's `JOB_OBJECT_MSG_JOB_MEMORY_LIMIT` was 8;
it is 10.

## What changed

| File | What |
|---|---|
| `src/process.zig` | `Limits`, `Job`, `Report`, `Child.waitReport`, the port's `drain`, `chooseProcessors`, `cpuRate`, `ownCpus`, `job_count_vars`; `newJob` takes limits |
| `src/win32.zig` | job limit flags, CPU rate control, the job's port, processor and group declarations |
| `src/override.zig` | `Settings.memory`, `Settings.cpus`, `limits()`, `parseMemory`, `parseCpus`, `Size` |
| `src/main.zig` | `--memory` and `--cpus` for `run`, `override` and `build`; usage |
| `src/run.zig` | the job's limits, the variables, the note when the limit is reached, `-v` lines |
| `src/builder.zig` | `Options.limits`, the variables, each command's report |
| `src/environment.zig` | `has` |
| `tests/jobprobe.zig` | `cpus`, `alloc`, and `injob`'s `--memory`, `--cpus`, `--rate`, `--report` |
| `tests/limits.sh` (new) | 68 rows |
| `.github/workflows/reproduce.yml` | a step for it, after `tests/volumes.sh` |
| `README.md`, `docs/how-it-works.md`, `docs/gaps.md`, `docs/findings.md` | the options, how the job is set up, what limits don't do, the probe's table |
| `build.zig.zon`, `zigsaw.json` | 0.93.0 |

## Tests

`tests/limits.sh` (a temporary store, a BusyBox app and the probe; 16 s here):

- in each of soft, low and appcontainer: a run without limits has neither; under `--memory` a
  run that stays below hears nothing; one that goes past is refused, and zigsaw names the limit;
  a child process's memory counts; the exit code is still the app's; `--cpus=2` gives two
  processors, the rate cap, `nproc` 2, both variables, and leaves a variable `--env` sets;
  `--cpus=9999` limits and sets nothing;
- overrides: saved and shown, held through the app's shim, a run's own value over it, `none`
  and `all`, `--global` under an app's own, `--reset`; what `-v` prints; the four refused values;
- builds: no limit, `--cpus=2` (processors, variables, a module's own `CARGO_BUILD_JOBS` kept),
  `--cpus` with every processor, `--memory` below and past, the build failing as its command
  does, and the same build going through without the limit.

Unit tests: the choice of processors (two per core, a mask with gaps, two kinds of core, no
core information), the rate's rounding, the settings' layers, their text and their JSON.

Results on this machine, final build:

| Suite | Result |
|---|---|
| `zig build test` | pass |
| `tests/limits.sh` | 68 ok, 16 s |
| `tests/shims.sh`, `ctrlc.sh`, `volumes.sh`, `batch.sh`, `store.sh` | 57, 28, 135, 12, 17 ok |
| `tests/sandbox.sh`, `tests/lazy.sh` | 142 and 33 ok, with their temporary folder on D: |
| `tests/build.sh`, every group | base 113, zig 37, cmake-meson 21, langs 55 ok |
| the package | `zigsaw.exe` `86e04a4e`, 0.93.0; Defender finds nothing in its six programs |

## A real cargo build

The Rust fixture of `tests/build.sh` (its `build.rs` made to print what cargo tells build
scripts), in a store with Rust 1.99.1, by `zigsaw -v build --rebuild`:

| Options | cargo's jobs (`NUM_JOBS`) | Rust's own count | Time | Peak memory |
|---|---|---|---|---|
| none | 16 | 16 | 6.7 s | 527 MB |
| `--cpus=4` | 4 | 16 | 4.5 s | 505 MB |
| `--cpus=4 --memory=8GB` | 4 | 16 | 4.6 s | 504 MB |
| `--memory=300MB` | 16 | 16 | fails in 1 s | |

- **cargo starts 4 compilers under `--cpus=4`**, by the variable: Rust's own count stays 16.
  The fixture is too small for the memory to differ much (9 crates); it is the count that
  was Rnote's trouble.
- **rustc refused memory doesn't say so.** Under 300 MB it printed 33 errors of the kind
  ``cannot find value `result` in this scope`` in a crate that compiles, and cargo exit code
  101: as in iteration 60, where the machine itself ran out and rustc left a broken `.rmeta`.
  zigsaw's line, `reached the build's memory limit of 300MB (--memory), and was refused more`,
  is the only one in the log that names the cause.

## What I got wrong on the way

- **What programs count**, as said under Decisions: I answered your first question from memory,
  and the probe corrected it.
- **The message number** for a memory limit, 8 in the plan, is 10. The probe printed what
  came.
- **Six AppContainer rows of the new suite failed** with no output and exit code 0. I took it
  for the limits' doing and compared with 0.92, which does the same: BusyBox's sh in an
  AppContainer doesn't wait for the last command of `sh -c`, which [gaps.md](gaps.md) already
  says. The suite's scripts end in `exit $?` now.
- **A probe of mine committed about 36 GB of this machine's memory** for a moment:
  `jobprobe alloc 99999999` in a run with no limit, to see a failure, which came only when
  Windows itself refused. Released at once; nothing else failed that I saw.
- **The suite's first cleanup left its store behind**: the image a build used as its SDK stays
  until `prune --downloads`, and only zigsaw can delete its deployment. It removes and prunes
  first now, as `tests/build.sh` does.
- **I ran `git stash` while suites were running in the background**, to see whether a
  formatting complaint in `src/win32.zig` was mine (it isn't: HEAD has it). The tree was back
  within a second and the suites ran a frozen zigsaw, but `tests/lazy.sh` builds the probe from
  the tree at its start.

## Not checked

- **A runner.** `tests/limits.sh` asks for 2 of the machine's processors and expects all of
  them without a limit; a runner has 4, another Windows build, and its own job around
  everything. If the runner's job has a CPU rate of its own, Windows may refuse ours, which
  zigsaw passes over, and the row that looks for the rate would fail.
- **A machine with two kinds of core, or more than 64 processors.** The choice of processors
  is unit-tested with made-up cores; this machine has 8 alike.
- **An app's run inside another's limited run** (`--share=commands`). Measured with a job
  inside a job: the inner one keeps the outer's processors and memory limit, shows no CPU rate
  of its own, and only the outer one's port hears of the limit.
- **A GUI app.** The note goes to stderr, which a GUI shim shows in its box when the run
  fails; no window was opened to see it.
- **A standard user.** Everything here ran in a session that isn't elevated, of an account
  that is in the Administrators group; `tests/standard-user.sh` doesn't run the new suite.
- **Rnote itself**, the build this was for: 20 minutes, and its recipe keeps
  `CARGO_BUILD_JOBS=8`. The cargo fixture above stands in.
- **A long build under `--memory`**: the port is emptied four times a second; no build of
  thousands of processes was run under a limit to watch zigsaw's own memory.
- **Whether the rate cap ever throttles a tree the affinity doesn't.** Four busy processes
  measured the same with and without it; a tree with more runnable threads than processors
  wasn't timed.
- `tests/matrix.sh`, `self.sh`, `upgrade.sh`, `rollback.sh` and the GUI suites weren't run. An
  overrides file with `memory` or `cpus` in it makes a zigsaw before 0.93 refuse to read it
  (it says to fix or reset it), as every new saved option has.

## Yours to do

- Commit and push. I read the Reproduce run, `tests/limits.sh` first: its first run on a
  runner, which has 4 processors, another Windows build, and a job of the runner's own around
  everything.
- The tag `v0.93.0` is yours; I read the Release run after it.
