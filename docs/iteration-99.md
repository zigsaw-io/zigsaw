# Iteration 99: Into a run

Started 2026-11-14, from "plan to implement exec command for in-sandbox command execution".
Since 97 and 98, `zigsaw ps` lists the runs going and `zigsaw stop` ends them, but nothing
could get into one. `zigsaw run --command=sh org.x` starts another run, with a job, relay
and ports of its own, a fresh data directory if the first was `--ephemeral`, and none of
the first run's `--env`, `--volume` or `--allow-host`. Now **`zigsaw exec` starts a command
in a run that's going, as the run's own app goes: in its job, with its token or
AppContainer identity, its variables and its working directory.** zigsaw is **0.99.0**. No
recipe or image changes, so there's nothing to publish. How it's used is in
[the README](../README.md#running-a-command-in-a-run).

State at the start: 98 had landed (`1b11a2c`, Reproduce 43468958786 and Release
43477752480 green).

## Outcome

- **`zigsaw exec [--env=NAME=VALUE]... [-d|--detach] <app-id>|<run> <command> [<arg>...]`**.
  The run is named as `ps` names it. An app with more than one run going is refused, with
  their numbers. The command is found as `run --command` finds one: an export (with its
  arguments), the run's PATH (aliases, the app's, its runtimes' and extensions'), System32,
  or an absolute path. A batch file goes through cmd.exe.
- The command **uses the terminal `exec` was typed in**, and `exec` ends with its exit
  code. Ctrl+C reaches it, and `exec` ignores it, as `run` does.
- It **sees what the run sees**: the run's data directory (an `--ephemeral` one too), its
  volumes and grants, its keys in HKCU, its relay and ports. It runs at the run's integrity
  level, or in its AppContainer with the run's capabilities.
- **`ps` lists it as its own row**, `(exec in run 4812)`. `ps --processes` shows it in the
  run's tree as one line, `-> exec 5120`, and its processes under its own row. The run's
  PROCS, MEMORY and CPU count it, because it's in the run's job.
- **`stop` and `kill` take it** as they take a run, leaving the run going. Stopping or
  killing the run ends its execs first.
- **It ends when the run ends** (`zigsaw: org.x's run 4812 ended, and with it this
  command`, exit code 1), and **when its `zigsaw exec` ends**.
- **`--detach`** starts it with no console and stdio on NUL, prints the number `ps` lists
  it by, and returns. A zigsaw of its own stays behind to wait for it.
- **Refused**: nothing running by that name; an app with two runs; a build's number ("exec
  joins runs"); an exec's number ("name the run instead"); a run whose zigsaw is older
  than 0.99, or couldn't write its spec; and a `zigsaw exec` below medium integrity, which
  can't read the spec.

## Decisions

Yours, by the question dialog:

- **The run writes down how it starts programs**, and `exec` starts the command itself,
  over the run's zigsaw starting it on request through a pipe.
- **An exec gets its own `ps` row and can be stopped**, over showing only in the run's
  process tree.
- **It ends with its `exec`**, as well as with the run, over going on until the run ends.
- **`--env` and `--detach`** this time. No `--workdir`, and no shell when the command is
  left out.

Mine:

- **The spec is `running\<pid>.spec`, next to the record, not `.json`**: `ps` takes every
  `.json` there for a record, and would have taken the spec's "lock" and deleted it. It
  goes when the record goes: by the run's zigsaw, or by `ps` after a killed one.
- **The spec is made with a medium label and NO_READ_UP**, set as the file is created.
  A low run reads what you can, and the spec holds the run's variables, `--env`'s among
  them. Labelling it afterwards would need the right to change its owner, which a store on
  a drive that gives users only Modify doesn't give. `writeLabel`'s way around that prints
  an error when it fails, which a run that goes on fine shouldn't.
- **Exports go in the spec already expanded**, with the run's own placeholders (its data
  directory, ports, runtimes), so `exec` needs neither the image nor the run's options.
- **Two jobs at once**: the command is started with PROC_THREAD_ATTRIBUTE_JOB_LIST = {the
  run's job, a new job of exec's}. The empty one nests in the run's: the run's limits hold
  the command, ending the run's job ends it, and ending exec's job (its zigsaw ending, or
  `stop`) ends only it. `process.SpawnSpec.outer_jobs` takes the outer ones.
- **`exec` lets go of the run's job as soon as the command has started.** Holding it would
  keep the run's job from ending when the run's zigsaw closes it.
- **A run that was ending is checked for after the start** (the probe below). If its app
  has ended, the command is ended and `exec` fails: "ended as the command started".
- **"The run ended it"** means the run's app ended, and the command no sooner (by their
  exit times). `exec` then says so and returns 1, even if the command's own code was 0,
  which is what ending the job by closing it gives.
- **The spec is read for up to 2 s** if it isn't there yet: a run writes it just after its
  record, which is what `exec` finds the run by.
- **`--detach` starts `zigsaw exec --detached-child`** (hidden, same options), out of
  exec's jobs if they let it (`process.startDetachedWith`, new: `startDetached` with
  stdio). It writes `started` on a pipe once its record is there, then puts NUL in its
  standard handles. The `exec` that started it prints its PID; with no `started`, it prints
  what came on the other pipe, which is why. Everything is checked before (the run, the
  spec, the command), so the usual errors come at once.

## Probe

Done first (`E:\zs\i99\probe\jobjoin.c`, a C program, against real zigsaw runs):

- **JOB_LIST with {a named job opened from another process, a new job}** works for soft,
  low and AppContainer tokens: the command is in both jobs, and listed in both.
- **A job its run has just ended** (TerminateJobObject) still takes a new process, which
  then lives until the last handle to the job is closed, and ends with exit code 0, not 1.
  That's the check after the start, and the exit-time rule above.
- **A medium NO_READ_UP label** keeps a low run's `cat` out ("Permission denied") while
  medium reads, and a rename keeps it. Setting it on an existing file failed (error 5) on
  E: (users have Modify there, not WRITE_OWNER); that's why the spec is made with it.
- **A detached waiter**: checked through `exec -d` itself, in the suite: `ps` lists it,
  and killing its zigsaw ends its command. Its command starts with CREATE_NO_WINDOW;
  whether a window flashes on the desktop wasn't looked at.

## Files

- `src/exec.zig` (new): the spec (`Spec`, `writeSpec`, `capabilityStrings`), the command,
  `--detach`; unit tests for the spec's round trip and command lookup.
- `src/run.zig`: writes the spec; `Command`, `findCommand` and `commandLine` (new, shared
  with exec) public.
- `src/process.zig`: `SpawnSpec.outer_jobs`, `startDetachedWith`.
- `src/ps.zig`: kind `exec`, `Record.run`, `specPath`, the spec deleted with the record,
  nesting by `run`, the `-> exec` line.
- `src/stop.zig`: an exec ends by its own job; `openZigsaw` public.
- `src/acl.zig`: `writeUnreadableBelowMedium`.
- `src/win32.zig`: a few declarations. `src/main.zig`: the command, its usage.
- `tests/exec.sh` (new), a step for it in `.github/workflows/reproduce.yml`;
  `docs/testing.md`; README.

## Results

| what | result |
|---|---|
| unit tests | all pass; new in `src/exec.zig` (the spec's round trip, finding a command) |
| `tests/exec.sh` | 56 ok, twice on the final build and twice before the last change (17-20 s) |
| `tests/ps.sh`, `stop.sh`, `limits.sh`, `ctrlc.sh`, `sandbox.sh`, `volumes.sh`, `build.sh` (base) | 44, 48, 68, 28, 142, 135 and 113 ok; 0 failed |
| the package | zip `90b88d23`, 0.99.0; Defender finds nothing in its six programs |

Between the long suites and the last runs, two changes went in from reading the diff:
writing the spec can no longer fail a run whose app has started (an AppContainer run whose
capabilities couldn't be written down gets a spec exec refuses), and that failure prints
nothing. `exec.sh`, `ps.sh` and `stop.sh` ran again after them; the others didn't.

## Not checked

- **A standard user**, `tests/matrix.sh`, the GUI suites and the other `build.sh` groups.
- **A GUI command through exec**: a window from a run's AppContainer was seen in 98's
  probe, but not one exec started.
- **A real app's run** (PostgreSQL's psql in its server's run, say): only BusyBox.

## Not this time

- `--workdir`, a shell when no command is given, exec into a build's command.
- 98's Ctrl+C guard doesn't count an exec's zigsaw as the run's. A run whose console also
  has an exec on it gets no Ctrl+C from `stop`, says so, and is killed after `--time`.
- Commands an exec'd `npm i -g` installs get their shims when the **run** ends, as after
  any run, not when the exec does.

## Yours to do

- Commit and push (`src/exec.zig`, `tests/exec.sh` and this file are new). I read the
  Reproduce run, `tests/exec.sh` first.
- The tag `v0.99.0` is yours; I read the Release run after it.
