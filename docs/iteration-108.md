# Iteration 108: JSON from what changes something

Started 2026-11-21, from "plan to support JSON for mutating commands". 107 gave
`--format=json` to the commands that read, and left out those that do something: a script
that installs, updates, starts or prunes still read stderr's notes ("updated id 1 -> 2
(d1 -> d2)"), or the bare number `run -d` prints. **Now every command that changes
something takes `--format=json` too, and prints what it did, once it's done**, with the
keys [docs/json.md](json.md) lists. The text doesn't change, nor does stderr. zigsaw is
**0.108.0**. No recipe or image changes, so there's nothing to publish.

State at the start: 107 had landed (`9afcdfa`, Reproduce 44867855719 and Release v0.107.0
44872041844 green, its sign job too).

## Outcome

- **`--format=json` on every command that changes something**: `install`, `build` (a
  project's `"apps"` too), `update`, `rollback`, `uninstall` and `uninstall --unused`,
  `upgrade`, `mask` with apps and `--remove`, `override`, `run -d`, `enter -d`, `kill`,
  `up -d`, `down`, `volume create`, `rm`, `prune`, `export` and `import`, `remote-add`,
  `remote-modify` and `remote-delete`, `build-export`, `build-update-repo`, `build-sign`,
  `repair`, `permission-remove`, and `updates on` and `off`.
  - One value, written once the command is done. What it says as it goes stays on
    stderr, and its questions are asked as in text (your pick): `--yes` answers them.
  - A command that stops at a failure prints nothing, as 107's do (your pick). One that
    goes on past failures prints what it did with what failed, and exits 1: `update`,
    `repair`, `kill` and `down`, as `update --check` did already.
  - What installs an app prints the app's `list` object, with what it replaced; `build`
    an array of those, with whether the build was reused.
- **Only what prints something else on stdout refuses it**, saying why: `logs`, `up`
  without `-d`, `run` and `enter` without `-d` (the app's output), `remote-info --file=`,
  `volume export` to `-`, `build-sign --print-payload`, `updates check --notify` and
  `--quiet`. `run` and `enter` take `--format` among their own options, before the app;
  after it, it's the app's.
- **Nothing but the JSON reaches stdout.** A build's tools wrote on zigsaw's stdout,
  and still do in text; under `--format=json` they get its stderr as their stdout, as
  do the zigsaws `upgrade` starts. A run's log tail, which `up` shows when an app fails
  to start, goes to stderr then too.
- **`volume rm` checks every name before it removes any**, in text too: `volume rm a b`
  with no volume `b` used to remove `a` and then fail. It now fails and leaves `a`.
- **`override <app-id>` without options**, which shows what's saved, takes
  `--format=json` too; 107 refused it.

## Decisions

| Decision | Choice |
|---|---|
| Which commands | Every one that changes something (your pick) |
| On failure | Nothing on stdout, as 107 (your pick); going on past failures: the object with `failed`, exit 1 |
| Questions | Asked as in text, on stderr (your pick) |
| Where it's written | Library functions return what they did; the command writes it, once. So an install inside an update, an `up` or a project's build writes nothing of its own |
| An app's result | `list`'s object for it, plus keys: `install`, `build` and `list` agree |
| A build's tools | Their stdout goes to stderr under JSON; in text it's as it was |
| `kill --now` | `outcome` `killed` for one it ended, `ended` for one that had ended by then: the text's two lines |
| `volume rm` | All names checked first: a failure that leaves half done would print nothing of what it did |

## Files

- `src/output.zig`: `refused` turned around, a short list of what prints something else,
  each with why; `parse` and `checkDetached` for `run` and `enter`.
- `src/Context.zig`: `childStdio` (a child's stdout to stderr under JSON),
  `stderrFile`.
- `src/main.zig`: each command writes its result; `run`, `enter` and `up`'s entries read
  `--format`; the help paragraph.
- `src/info.zig`: `listed`, `list`'s object for one app.
- `src/install.zig` (`Installed`, `Image.reused`), `src/builder.zig`, `src/compose.zig`
  (`BuiltApp`), `src/update.zig` (`Outcome`), `src/rollback.zig`, `src/prune.zig`,
  `src/upgrade.zig`, `src/run.zig`, `src/exec.zig`, `src/stop.zig` (`Row`, `Ended`),
  `src/up.zig`, `src/logs.zig`, `src/volumes.zig` (`Pruned.removed`, `rm` checking
  first), `src/remotes.zig`, `src/remote.zig` (`Pushed`, `Signed`), `src/catalog.zig`,
  `src/exports.zig` (`Repaired`), `src/grants.zig` (`TakenBack`), `src/container.zig`,
  `src/msvc.zig`.
- `tests/json-changes.sh` (new), and a step in `.github/workflows/reproduce.yml`;
  `tests/json.sh`'s refusal rows.
- `docs/json.md` ("Commands that change something"), README, `docs/testing.md`; 0.108.0
  in `build.zig.zon` and `zigsaw.json`.

## Results

All here, with one build frozen for the suites (`E:\zs\i108\bin`), TMPDIR on D:, and zot
from `D:\zs\i87\zot` for the suites under `tests/zot.sh`.

| what | result |
|---|---|
| unit tests | pass: what `take` refuses and passes, `run`'s and `enter`'s `--format` |
| `tests/json-changes.sh` | 31 ok, 0 failed, in 12 s (27 without a registry) |
| `tests/json.sh` | 30 ok, 0 failed: its refusal rows are those still refused |
| suites that read the text of what changed | `tests/store.sh` 31 ok, `volumes.sh` 135, `ps.sh` 44, `stop.sh` 48, `exec.sh` 56, `up.sh` 91, `doctor.sh` 81, `limits.sh` 68, `updates.sh` 42, `rollback.sh` 56, `lazy.sh` 37, `signing.sh` 58, `oci.sh` 35, `registry.sh` 124; 0 failed |
| `tests/self.sh` | 20 ok, 0 failed (its help line is unchanged) |
| Defender | `scripts/defender-scan.sh` on `scripts/package.sh`'s zip: the six programs clean |

## Not checked

- **`upgrade --format=json`**: it needs a newer release than the zigsaw that runs it;
  `tests/upgrade.sh` runs it in text.
- **`build-sign --format=json`**: `tests/signing.sh` signs in text; the JSON is the same
  values the notes say.
- **jq on CI's runners** for the new suite: `tests/json.sh` needs it already, and passed.

## Not this time

- Errors as JSON.
- JSON lines from what streams: `logs`, `up` without `-d`, a build's progress.
- Moving the suites' awk onto `--format=json`.

## Yours to do

1. **Commit and push.** `tests/json-changes.sh` is new and executable:

   ```
   git add --chmod=+x tests/json-changes.sh
   ```

   I read the Reproduce run: `tests/json-changes.sh` and `tests/json.sh` first. The
   workflow changed, so every group runs.
2. **Tag v0.108.0** when you're ready; I read its Release run.
