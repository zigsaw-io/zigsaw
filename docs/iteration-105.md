# Iteration 105: Flatpak's commands

Started 2026-11-20, from "the current CLI is a bit too Docker-ish. I want to streamline it
to Flatpak". zigsaw is "Flatpak for Windows", but over a hundred iterations its commands
had become Docker's: `pull`, `push`, `rm`, `prune`, `exec`, `stop`, `login`, `ls`, `cat`,
next to Flatpak's `run`, `override` and `update`. Now **zigsaw's commands are Flatpak's
wherever Flatpak has one, apps come from named remotes as Flatpak's do, and publishing is
the `build-*` family**. What Flatpak has no command for keeps its name, in a section of
its own. zigsaw is **0.105.0**. No recipe or image changes, so there's nothing to
publish. The commands are in [the README](../README.md#commands).

State at the start: 104 had landed (`d7325a2`, Reproduce 44444265874 and Release v0.104.0
44458862424 green). The WFP experiment's branch stays as it was.

## Outcome

| Before | Now | Flatpak's |
|---|---|---|
| `pull <image>` | `install [-y] [--lazy] [<remote>] <image>` | `flatpak install` |
| `rm [--delete-data]` | `uninstall [--delete-data]` | the same flag |
| `prune [...]` | `uninstall --unused [...]` | `flatpak uninstall --unused` |
| `info <image>`, `ls`, `cat` | `remote-info [--show-files \| --file=<path>] [<remote>] <image>` | `flatpak remote-info` |
| (none) | `info <app-id>`: an installed app, its origin and remote, where its files and data are, masked or not, the version rollback goes back to | `flatpak info` |
| `stop`, `kill` | `kill [--time=<s>]`, `kill --now` | `flatpak kill` |
| `exec` | `enter` (ps lists `(enter in run <n>)`) | `flatpak enter` |
| `hold`, `unhold` | `mask`, `mask --remove`; `mask` alone lists them | `flatpak mask` |
| `grants`, `grants --take-back` | `permissions`, `permission-remove` | `flatpak permissions` |
| `ZIGSAW_REGISTRY`, `login`, `logout`, `trust` | `remotes`, `remote-add`, `remote-modify`, `remote-delete`, `remote-ls` | Flatpak's remotes |
| `push`, `push --catalog` | `build-export [<remote> \| <image>]`, `build-update-repo [<remote>]` | `flatpak build-export`, `build-update-repo` |
| `signature payload/push/push-bundle/check` | `build-sign --print-payload`, `build-sign`, `build-sign --bundle`, `build-sign --check` | `flatpak build-sign` |

- **Old names fail, saying the new** (your pick): `` `zigsaw pull` is `zigsaw install`
  since zigsaw 0.105, whose commands are Flatpak's ``. Pointers follow the arguments:
  `push --catalog` points at `build-update-repo`, `grants --take-back` at
  `permission-remove`, `trust add ... --keyless` at `remote-modify --keyless=<identity>`.
  They're checked before the store is opened, so they change nothing.
- **`-y`** agrees wherever `--yes` does, as Flatpak's `-y`.
- **Help** is grouped as `flatpak --help` is: installed apps, finding apps, running,
  permissions, remotes, building and publishing, then **zigsaw's own**: `run -d`, `logs`,
  `up`, `down`, `volume`, `rollback`, `doctor`, `updates`, `upgrade`, `version`, under
  their names (your pick).
- **Remotes** (`src/remotes.zig`): a name for a registry and a path in it. A store has
  `zigsaw` (ghcr.io/zigsaw-io) until told otherwise, kept in `remotes.json`. An app
  named by id alone comes from the first; another is named before it (`install mine
  org.x.App`), as `flatpak install <remote> <ref>`. `search` reads every remote's
  catalog, with a REMOTE column when there's more than one, and goes on past one
  without a catalog. Locations take Flatpak's `oci+https://` too. Names are letters,
  digits, `-` and `_`, so a name is never an app id or an image's name.
- **A remote's signers** are trust.json's entries for its location, as before:
  `--sign-key=<file>`, `--keyless=<identity> [--issuer=<url>]`,
  `--no-sign-key[=<which>]`. `--url` moves them along. `remote-add` checks keys and
  identities first and adds nothing unless it can add all. Places a zigsaw before 0.105
  was told to `trust add` become remotes, named after their last part, once, with a note.
- **A remote's login** is `--login [--username] [--password-stdin]` and `--logout`, for
  its registry's host, in Windows Credential Manager as before: logins saved by `zigsaw
  login` go on working. Messages that ask for a login name the remote's `remote-modify
  --login <name>`, or `remote-add --login` when no remote is on the registry.
- **`remote-delete`** takes the remote's signers with it, and refuses a remote apps were
  installed from unless given `--force`, as their updates are checked for its signatures
  (Flatpak refuses one with installed refs too). It never deletes a login: Windows keeps
  them for the user, and every store uses them; it says how to delete one.
- **`ZIGSAW_REGISTRY`** moves the first remote for as long as it's set, which CI and the
  tests rely on; nothing saves it.

## Decisions

| Decision | Choice |
|---|---|
| Docker's own (volumes, `run -d` + `logs`, `up`/`down`) | Kept, in their own section (your pick) |
| Remotes | Yes (your pick), with login and signature trust as a remote's options |
| Publishing | The `build-*` family (your pick) |
| Old names | Fail, pointing at the new (your pick); no aliases |
| An app id with several remotes | The first remote, or the one named; zigsaw doesn't ask each remote in turn, as that would reach the network for every pinned image a build resolves, and print errors for remotes without the app. `search` shows where each app is |
| `stop` and `kill` | One `kill`, asking first as `stop` did; `--now` for what `kill` was |
| `info` | The installed app's (Flatpak's meaning); a registry's is `remote-info` |
| `remote-delete` and logins | Logins stay: they're per Windows user, shared by every store |

## Files

- `src/remotes.zig` (new): the remotes, `remotes`, `remote-add/-modify/-delete`, login
  hints, and taking in `trust add`'s places.
- `src/main.zig`: the grouped help, the new commands, `movedCommand` (with a test),
  `inRemote`, `parseRemoteOptions`, `buildSignCommand`; `login`, `logout`, `trust` gone.
- `src/info.zig`: `installedInfo`, `remoteInfo`; `writeDownload` apart from
  `writeContents`. `src/catalog.zig`: a catalog per remote, `search` over all.
  `src/remote.zig`: `resolve` through remotes, `resolveAt`. `src/trust.zig`:
  `addedPrefixes`, `movePrefix`, `removeAll`, `check`, `releaseSigners`; `list` gone.
  `src/credentials.zig`, `src/Registry.zig`: login wording. `src/Context.zig`: `remote`,
  `store_open`. `src/rollback.zig`: `listHeld`, masked wording. `src/exec.zig`:
  `enter --detached-child`. `src/ps.zig`: `(enter in run <n>)`.
- Every message naming an old command, across `src/`.
- Every suite, script and workflow that ran an old command. New rows: `tests/store.sh`
  (installed `info`, the pointers, `uninstall`'s options), `tests/registry.sh` (a remotes
  section, logins through a remote), `tests/rollback.sh` (`mask` lists),
  `tests/signing.sh` (signers given to remotes, `remote-add` all or nothing).
- `README.md` (the commands, remotes, signatures, logins), `docs/gaps.md`,
  `how-it-works.md`, `layer-formats.md`, `networking.md`, `published-apps.md`,
  `recipes.md`, `testing.md`, `update-and-clean-up.md`. Earlier write-ups and
  `findings.md` keep the names of their time.
- 0.105.0 in `build.zig.zon` and `zigsaw.json`.

## Results

Run here from a frozen copy of the build (`E:\zs\i105\bin`), against zot from
`D:\zs\i103\p` where a suite needs a registry. Rows marked * ran on the first slice's
build, before remotes; each of those touches nothing remotes changed, or ran again after.

| what | result |
|---|---|
| unit tests | 296 passed: `movedCommand`'s pointers, remote names, locations, a remote's name from `trust add`'s place |
| `tests/store.sh` | 31 ok, 0 failed, on the final build: installed `info`, the pointers, `uninstall`'s options |
| `tests/registry.sh` | 124 ok, 0 failed: the remotes section, logins through a remote, `--logout` |
| `tests/signing.sh` | 58 ok, 0 failed: keys and keyless identities given to remotes, `remote-add` all or nothing, `zigsaw's releases` in `remotes` |
| `tests/oci.sh` | 35 ok, 0 failed, 2 known gaps: cosign's signatures, its key given to a remote |
| `tests/rollback.sh`, `updates.sh`, `doctor.sh` | 56, 42, 83 ok, 0 failed: `mask`, and `mask` alone listing |
| `tests/stop.sh`, `exec.sh`, `volumes.sh` | 48, 56, 135 ok, 0 failed: `kill`, `kill --now`, `enter` (`-d` started `exec` before the fix), `(enter in run <n>)` |
| `tests/ps.sh`, `up.sh`, `shims.sh`, `lazy.sh` | 44, 91, 57, 37 ok, 0 failed, on the final build |
| `tests/build.sh`, group base | 131 ok, 0 failed |
| `tests/sandbox.sh` * | 142 ok, 0 failed (`permissions`) |
| the package | zip `8cc6cd1d`, 0.105.0; Defender finds nothing in its six programs |

Not run here: `tests/standard-user.sh` (its `--logout` row; CI's own account),
`tests/upgrade.sh` (from real v0.80.0 and v0.83.0: the old releases only run commands
whose names stayed), `tests/install.sh`, the GUI and app suites (only renamed calls).
CI runs all of them.

## Not this time

- Flatpak's `--user`/`--system`, branches (`//stable`), `history`, `config`, `pin`,
  `make-current`, `document-*`, `permission-set`, and `remote-ls --updates` (`update
  --check` says it).
- `doctor` reads no store's remotes (it opens no store): it checks `ZIGSAW_REGISTRY`, or
  ghcr.io/zigsaw-io, as before.
- `list` has no origin column; `info` says it.
- Remotes have no priority option; the order is the order they were added in.

## Yours to do

1. Commit and push (`src/remotes.zig` and this file are new). I read the Reproduce run:
   the suites group first (store, registry, signing, rollback, stop, exec, oci).
2. The tag `v0.105.0` is yours; I read the Release run after it. Scripts of yours that
   run `zigsaw pull`, `login` or `trust` need the new names: the old ones fail.
