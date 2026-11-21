# Iteration 107: JSON output

Started 2026-11-21, from "plan to implement CLI's JSON output". Scripts, and zigsaw's own
tests, read zigsaw's text with awk: `list | awk '$1 == id { print $3 }'`, `ps | awk 'NR == 2'`.
That breaks when a line is reworded, and the text's values ("1.2 MiB", "4m 07s", digests
cut to 12 digits) can't be read back. **Now every command that prints something to read
takes `--format=json`, and prints one JSON value on stdout in place of its text**, with
the keys [docs/json.md](json.md) lists. The text doesn't change. zigsaw is **0.107.0**:
iterations number versions, so there's no 0.106.0, as there was no 0.88.0. No recipe or
image changes, so there's nothing to publish.

Before that, a fix: v0.105.0's Release run, after the re-tag, published the release but
didn't sign it.

State at the start: 106 had landed (`4c681ea`, Reproduce 44845418861 green). The re-tagged
v0.105.0's Release run (44856418195) published v0.105.0, which GitHub shows as Latest, but
its `sign` job failed.

## Outcome

- **The sign job installs cosign with `install`.** `scripts/sign-release.sh --keyless` gets
  cosign with the zigsaw it has just built, and still called `zigsaw pull`, which became
  `install` in 0.105. No test reaches that line: tests/oci.sh runs the script with `COSIGN`
  set. **v0.105.0 stays unsigned** (your pick), so `zigsaw upgrade` to it warns that the
  signature is missing; v0.107.0 takes its place, signed keyless.
- **`scripts/check-commands.sh`**, in the `pins` job, fails if a script or workflow calls
  zigsaw by a name it had before 0.105. It found that line, and nothing else.
- **`--format=json` on 16 commands**, `--format json` too: `list`, `info`, `remote-info`
  and its `--show-files`, `search`, `remote-ls`, `remotes`, `ps` and its `--processes`,
  `mask`, `update --check`, `updates` and `updates check`, `permissions`, `volume ls`,
  `volume inspect`, `doctor` and `version`. `--format=text` is the text.
  - An array for a listing, an object for the rest, indented. Every key is there, null
    when there's nothing to say. Sizes are bytes, times RFC 3339 in UTC, processor time
    milliseconds, digests whole.
  - Exit codes and stderr are the text's. A command that fails prints nothing on stdout.
    Where text says on stderr that there's nothing to list, JSON prints `[]`: `ps` with
    nothing running, `search` finding nothing (still exit 1).
  - Every other command refuses `--format=json`, naming those that take it; so do the forms
    of these that print nothing to read (`update` without `--check`, `mask --remove`,
    `remote-info --file=`, `volume rm`, `updates on`). `run` and `enter` don't look:
    what follows the app is the app's.
- **What an update adds is kept as data.** `update --check` and `updates` say what a new
  image may reach beyond the installed one; that was only ever text. A check keeps it in
  `updates\state.json` as `adds` too. Older zigsaws read the file as before (they skip keys
  they don't know), and what an older zigsaw found has `adds: null`.
- **Help** has a paragraph on `--format=json`; the README a paragraph under Commands, with
  examples.

## Decisions

| Decision | Choice |
|---|---|
| Which commands | Every command that prints data (your pick), in one iteration |
| How it's asked for | `--format=json` (your pick), as Docker and Podman spell it; `--format json` and `--format=text` too |
| v0.105.0 | Left unsigned (your pick); v0.107.0 replaces it |
| Keys | snake_case, as the store's own files; every key there, null for nothing, so a script can tell "no summary" from a zigsaw that doesn't know the key. Two values keep the shape of what they come from: `override` (the saved file) and `permissions` (the image's config) |
| Values | Raw: bytes, RFC 3339, milliseconds, whole digests. The text keeps its own |
| Empty | `[]` where text has a note on stderr; the note goes. Other notes stay on stderr |
| Stability | Keys are added, not renamed or removed; a release that must says so. `tests/json.sh` lists each object's keys, so a change shows |
| Existing scripts and tests | Keep reading text. `scripts/publish.sh` runs a frozen 0.105.0, and `tests/upgrade.sh` v0.80 and v0.83, which know no `--format`; and the awk in the suites checks that the text stays as it is |
| `doctor` | JSON comes out once the report is done; the text still comes out section by section |

## Files

- `src/output.zig` (new): `Format`, `take` (takes `--format` out of the arguments, refuses
  what prints no JSON), `write`, `merged` (one object from several structs: `info` and
  `remote-info` share the middle), `Time` (RFC 3339), `nothing` (`[]`).
- `src/Context.zig`: `format`; `stdoutFailed`, moved from peek.zig.
- `src/main.zig`: `output.take` before the commands; `version`; the help paragraph; `list`
  moved to info.zig.
- `src/info.zig`: `list` (text and JSON from one record per app), `Contents` and
  `contentsOf` (what `info` and `remote-info` share), `info` and `remote-info` as JSON.
- `src/ps.zig`, `src/volumes.zig`, `src/rollback.zig`, `src/catalog.zig`, `src/remotes.zig`,
  `src/peek.zig`, `src/update.zig`, `src/updates.zig`, `src/grants.zig`, `src/doctor.zig`:
  each command's JSON. `lazy.progress` says where a lazy download is as data, and
  `describe` as text from it. `update.Waiting.adds`. `doctor.Report` keeps what it finds
  for one object at the end.
- `tests/json.sh` (new), and a step in `.github/workflows/reproduce.yml`;
  `scripts/check-commands.sh` (new), and a step in its `pins` job;
  `scripts/sign-release.sh`.
- `docs/json.md` (new), README, `docs/testing.md`; 0.107.0 in `build.zig.zon` and
  `zigsaw.json`.

## Results

All here, with one build frozen for the suites (`E:\zs\i107\bin`), TMPDIR on D:, and zot
from `D:\zs\i87\zot` for the suites under `tests/zot.sh`.

| what | result |
|---|---|
| unit tests | pass: `--format` taken and refused, RFC 3339, `merged`, `doctor`'s report as JSON, `state.json` with and without `adds` |
| `tests/json.sh` | 31 ok, 0 failed, in 12 s (22 without a registry, all of those passing alone too) |
| `scripts/check-commands.sh` | ok; with the old `sign-release.sh` it names line 119 |
| suites that read the text of what changed | `tests/store.sh` 31 ok, `volumes.sh` 135, `ps.sh` 44, `stop.sh` 48, `exec.sh` 56, `up.sh` 91, `doctor.sh` 81, `updates.sh` 42, `rollback.sh` 56, `lazy.sh` 37, `signing.sh` 58, `registry.sh` 124; 0 failed |
| `tests/self.sh` | 20 ok, 0 failed (its help line is unchanged) |
| Defender | `scripts/defender-scan.sh` on `scripts/package.sh`'s zip: the six programs clean |

## Not checked

- **jq on CI's Windows runners.** `tests/json.sh` needs it, as scripts here already do on
  Linux. GitHub's Windows images list it; if a runner lacks it, the step fails at once,
  saying so.
- **The keyless sign job**, until v0.107.0 is tagged.

## Not this time

- JSON from what does something (`install`, `run -d`'s run number, `enter -d`'s PID,
  `build`), and errors as JSON.
- `--columns`, as Flatpak's `list` and `ps` have.
- Moving the suites' awk onto `--format=json`.

## Yours to do

1. **Commit and push.** `scripts/check-commands.sh` and `tests/json.sh` are new and
   executable:

   ```
   git add --chmod=+x scripts/check-commands.sh tests/json.sh
   ```

   I read the Reproduce run: `pins` (check-commands) and `tests/json.sh` first. The
   workflow changed, so every group runs, GTK's and Qt's included.
2. **Tag v0.107.0** when you're ready; I read its Release run, its `sign` job above all.
