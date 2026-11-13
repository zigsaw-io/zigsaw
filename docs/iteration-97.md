# Iteration 97: What's running

Started 2026-11-13, from "plan to add `ps` process inspecting command". zigsaw could tell only
*whether* an app was running, by a lock its runs hold. It kept nothing of *which* runs were
going, and their job objects had no names, so no other process could look into them. An app
started from a shortcut, its tools, the relay, another app's run through `--share=commands`:
none of it could be seen, nor what it used against `--memory` and `--cpus`. Now **`zigsaw ps`
lists the runs and builds going in the store, by the PID of the zigsaw that runs each, with
its sandbox, processes, memory, processor time and command; `--processes` shows each one's
process tree.** zigsaw is **0.97.0**. No recipe or image changes, so there's nothing to publish.
How it's used is in [the README](../README.md#whats-running).

State at the start: 96 had landed (`e8fbb4d`, Reproduce 43335910068 and Release 43341901615
green).

## Outcome

- **`running\<pid>.json`** in the store: what each `zigsaw run` and `zigsaw build` says of itself
  (app, version, manifest, sandbox, network, limits, command line, shortcut, when it started,
  its job's name). Its zigsaw holds `running\<pid>.lock` exclusively while it goes. A lock ends
  however its zigsaw does, so `ps` deletes a record whose lock it can take: one a killed zigsaw
  left. A PID Windows gives again can't be mistaken for it.
- **Runs' jobs have names**, `Local\zigsaw.<pid>.<16 random hex>`. The random part means nobody
  can create the name first: one that exists already is not used, and the job goes unnamed, as
  it does when Windows refuses the name. `ps` opens a job with `JOB_OBJECT_QUERY` only.
- **`zigsaw ps`**: one line per run or build, oldest first, the columns as wide as what's in
  them. PROCS, MEMORY (committed, with the limit beside it) and CPU are the job's: the whole
  tree, a run inside it included.
- **`--processes`**: each run's processes from its job, each under the one that started it,
  oldest first, with its own committed memory, processor time, age and command line.
- **A run inside another** (its zigsaw is in the other's job, as a `--share=commands` command's
  is) is listed as `(in run <n>)`. The outer run's tree shows it as one line, `-> run <n>`, and
  its processes only under its own run.
- **Builds**: one record per `zigsaw build`, rewritten as each command starts, with the
  command's job's name. The COMMAND column says `[<module> <n>/<of>] <command>`, as the build's
  log does.
- **Filters**: `zigsaw ps <app-id>...` (any case) and `zigsaw ps <run>...`.

## Decisions

Yours, by the question dialogs, both the ones I recommended:

- **`ps` only looks**; stopping a run waits for an iteration of its own.
- **Runs and builds**, not the lazy-pull helpers.

Mine:

- **A named job, not a duplicated handle.** `ps` could have copied each run's job handle out
  of its zigsaw (`DuplicateHandle`), which needs no name, but needs `PROCESS_DUP_HANDLE` on that
  zigsaw: full control of it, for a command that only looks. A name in `Local\` is reachable by
  the user's medium-integrity programs. The job's default DACL and medium label keep low runs
  and AppContainer runs from opening it, as the probe below shows. A soft run could already do
  anything as the user, so the name gives it nothing new.
- **No `parent_run` field**, which the plan had. `ps` sees a run is inside another when that
  run's zigsaw is among the other's job's processes, which holds however the inner zigsaw was
  started. A run is inside the one with the fewest processes whose job has it.
- **The record is written once the app has started**, not before: only then is its PID known.
  A `ps` in the few milliseconds between doesn't list the run.
- **No store lock.** `ps` only reads, as `list` does; deleting a stale record needs only its own
  lock.
- **A build's record isn't rewritten when a command ends.** The job is gone by then, so opening
  it fails and `ps` shows `-`: one write per command, not two.
- **Writing the record fails soft.** A zigsaw that can't (one at low integrity) says so under
  `-v`, and the run or build goes on. Its processes are still in the job of the run it's inside.
- **COMMAND is cut at 80 characters on the summary line**, with `...`; `--processes` gives the
  whole command line of each process.

## Probe

Done first, on the real code path (`E:\zs\i97`): a BusyBox run held in each sandbox, then `ps
--processes` from a prompt. From medium integrity, `OpenJobObjectW`, the job's process list,
and for each process `QueryFullProcessImageNameW`, `GetProcessTimes`,
`K32GetProcessMemoryInfo` and `NtQueryInformationProcess(ProcessCommandLineInformation)` all
answered, for low and AppContainer processes as for soft ones. `taskkill /F` of a run's zigsaw
ended the app with it (the job's kill-on-close), and the next `ps` deleted the record.

## Files

- `src/ps.zig` (new): the record and its lock, `live`, the job and process readers, the
  command, its formats; 7 unit tests.
- `src/process.zig`: `newJob(…, name)`, `SpawnSpec.job_name`, `Job.name`, `Child.job_name`.
- `src/run.zig`: the job's name, the record around the run.
- `src/builder.zig`: the build's record, `Options.listed`, each command's job's name.
- `src/win32.zig`: Toolhelp, `OpenJobObjectW`, the process list, process times, memory and
  command line.
- `src/main.zig`, `src/Store.zig`: the command, its usage, `running` in the layout.
- `tests/ps.sh` (new), a step for it in `.github/workflows/reproduce.yml`; README.

## Results

| what | result |
|---|---|
| unit tests | all pass; 7 new in `src/ps.zig` (formats, `shortCommand`, `summary`, `matches`, `treeOrder`, a reused PID, records kept and dropped) |
| `tests/ps.sh` | 44 ok, 13 s |
| `tests/limits.sh`, `sandbox.sh`, `volumes.sh`, `build.sh` (base) | 68, 142, 135 and 113 ok; 0 failed |
| the package | zip `8bb03102`, 0.97.0; Defender finds nothing in its six programs |

## Not checked

- **A zigsaw at low integrity** (one that a low run's shim of an alias starts): that its record
  and the name of its job fail soft is code, not something a suite ran.
- **A GUI app from a shortcut**, by hand: the shim path is the same as a command's, which
  `ps.sh` runs; its `shortcut` field isn't shown anywhere yet.
- **A standard user**, `tests/matrix.sh`, the GUI suites and the other `build.sh` groups weren't
  run: what they cover changed only by the job's name and a file in the store.

## Yours to do

- Commit and push (`src/ps.zig`, `tests/ps.sh` and this file are new). I read the Reproduce run,
  `tests/ps.sh` first.
- The tag `v0.97.0` is yours; I read the Release run after it.
