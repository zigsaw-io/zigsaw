# Iteration 103: Builds without the network

Started 2026-11-18, from "plan to support no-network build step". A build's commands were
kept off the network by convention only: they got proxy variables pointing nowhere, which
curl, wget, npm and pip honour, and a tool that ignores them could still download. Now
**a recipe that says `"contained": true` has its build commands run in an AppContainer
with no network capability, where Windows can: they reach neither the internet nor this
machine's servers, and write only the build root.** Twenty-four published recipes say
so, each having built there to its published image. zigsaw is **0.103.0**. No image
changes, so there's nothing to publish. How recipes use it is in
[recipes](recipes.md#builds-in-a-container).

State at the start: 102 had landed (`0ecf2e4`, Reproduce 44226304142 green; the weekly
run of 2026-11-17, 43859927288, green too). That run's acprobe rows, printed from
CI's `windows-2025` runner, are all denied in a container: `NUL`, the program's own path,
its long name, the Mount Manager, the drive root.

## Outcome

- **`"contained": true`** in a recipe: its build commands run in `zigsaw.build`, an
  AppContainer of zigsaw's own that holds one capability of its own and no network one.
  The build root is granted to it in full, the build's tools to read and run. No app
  shares the profile, so no app's exemption from loopback isolation reaches it. Vendor
  steps, and modules with `"network": true`, run outside it, as before.
- **Where Windows can.** A build first runs a copy of zigsaw in the container
  (`zigsaw build-check`), which opens `NUL`, finds its own path with its drive letter and
  writes in the build root. The answer is kept in the store's `cache\build-container.txt`
  for that zigsaw on that Windows build and update. Where it fails, as on Windows Server
  2025, the commands run without the container, kept off the network only by proxy
  variables, and the build says so in a note.
- **`zigsaw build --sandbox=auto|appcontainer|soft`**: `auto` (the default) follows the
  recipe; `appcontainer` runs any recipe's commands in the container and fails where
  Windows can't, which is how to try a recipe; `soft` runs none there. Neither the
  option nor the way a build ran is one of its inputs or recorded in the image: it's
  the same image either way. Projects' builds pass it on.
- **`zigsaw ps`** shows a build's command in the container as `build, appcontainer`;
  **`zigsaw doctor`** says what the store remembers of the check.
- **BusyBox's sh in a container**: asked to run a program last, it doesn't wait for it
  (it can't find zigsaw, its parent, in Windows' list of processes), so the program died
  with the job. zigsaw adds `exit $?` after each contained command.

## Decisions

| Decision | Choice |
|---|---|
| How to enforce it | An AppContainer without network capabilities: the only thing Windows enforces without an administrator. A restricted token was probed and doesn't stop sockets |
| By default | Enforced where it works, after a check in the container; elsewhere the convention, with a note (your pick) |
| Who says a build can | The recipe, opting in, once it has built there to the published image (your pick after the probe): CI always runs the fallback, so a default of "contained" would break untried recipes only on Windows 11 |
| How far | Ship what works; Ninja, llvm-mingw, Python's private temporary folders, Gradle and TeX Live's installer go to [gaps](gaps.md) (your pick after the probe). Nothing republished |
| The container | One profile, `zigsaw.build`, for every build, never an app's: an app's loopback exemption would reach builds |
| The image | Doesn't record which way it was built: digests must match CI's, which can't contain |
| BusyBox's exec | `exit $?` after each contained sh command, rather than a helper process in the container: one line, and only make's shells under it, which see their parent, remain |
| The check | A copy of zigsaw in the build root, run in the container once per zigsaw and Windows build (with its update revision: an update lifted a restriction before) |

## Probe

The kit's notes are in `D:\zs\i103\notes.md`; [findings](findings.md#builds-in-a-container-iteration-103)
has the tables.

- A container sees `B:` (the logon session's DOS device) and its root's attributes once
  the folder is granted; a tool that ignores the proxy can't reach a server on this
  machine; writes outside the root are denied, and the real profile isn't there.
- Built in the container, these made their published images: SQLite, make, ZLS, 7-Zip,
  draw.io, VSCodium, Kanboard, hunspell's two dictionaries, Ghostscript, ripgrep, bat,
  cargo-c, fzf, cosign, oras, skopeo, zot, Perl, and PHP's apcu, igbinary, redis, ssh2 and
  xdebug.
- What fails: Ninja's pipes (zstd; a copy with the name patched built the same image),
  every LLVM program of llvm-mingw (gettext, pgvector, llvm-mingw's own test), Meson's
  Python, Gradle (PlantUML), TeX Live's installer (it writes `HKCU`).
- Windows sets a container's `TEMP` to its own folder under `LOCALAPPDATA`, in the
  build's profile; a vendor step makes that profile afresh, which first broke the Go
  builds with vendor steps (cosign, oras, skopeo, zot): the folder is now made before
  each module's commands.

## Files

- `src/container.zig` (new): the modes, the check and what it remembers, and the check
  itself (`zigsaw build-check`); a unit test for the remembered answer.
- `src/builder.zig`: `BuildRoot.containIf` and `contain` (the profile, grants, the
  container's `TEMP`), contained commands with `exit $?`, `Options.sandbox`, `ps`'s field.
- `src/recipe.zig`: `contained`, refused with host toolchains or without build commands;
  tests.
- `src/main.zig`: `--sandbox` for `build`, `build-check`, usage. `src/compose.zig`:
  sibling builds pass it on. `src/ps.zig`: the column. `src/doctor.zig`: the row.
- `tests/build.sh`: the `contained` section, in the `zig` group.
- 24 recipes with `"contained": true`.
- README, `docs/recipes.md`, `docs/networking.md`, `docs/gaps.md`, `docs/findings.md`,
  `docs/testing.md`; 0.103.0 in `build.zig.zon` and `zigsaw.json`.

## Results

| what | result |
|---|---|
| unit tests | pass, on the final source; new in `src/container.zig` (the remembered answer) and `src/recipe.zig` (`contained` refused with `host` or without build commands) |
| `tests/build.sh`, `contained` section | 18 ok, 0 failed: in the container, a tool that ignores the proxy reaches no server on this machine, and writes outside the root fail; `--sandbox` both ways; `"network"` outside; exit codes kept; `zig cc` and `zig ar` as last commands; the same image with and without the container; `TEMP` after a vendor step; then, with the store's answer set to Server 2025's, the fallback, its note, `--sandbox=appcontainer` failing and doctor's row |
| `tests/build.sh`, `zig` group | 52 ok, 0 failed (364 s) |
| `tests/doctor.sh`, `ps.sh`, `stop.sh`, `limits.sh` | 83, 44, 48 and 68 ok, 0 failed |
| the 24 recipes | each built in the container to the digest on ghcr.io, with `--sandbox=appcontainer` (cosign, oras, skopeo and zot after the `TEMP` fix); SQLite, fzf and PHP's apcu again with nothing but `"contained"`, the note saying so |
| the package | zip `8b87bdfa`, 0.103.0; Defender finds nothing in its six programs |

## Not checked

- **CI's side**: the fallback runs on Server 2025 only there; here the test fakes that
  Windows' answer in its store.
- **`tests/sandbox.sh` and `network.sh`**: not run again; runs' AppContainer code didn't
  change.
- **The recipes not tried in a container**: Qt's SDKs, the GTK family, PostgreSQL's and
  GDAL's, .NET's; they don't say `"contained"`, so they build as before.

## Not this time

- Ninja patched in CMake's image (republishing it and what pins it), llvm-mingw through
  `B:`, Python's private folders, Gradle.
- BusyBox's exec in `zigsaw run --sandbox=appcontainer` (see gaps).
- Removing the `zigsaw.build` profile, which stays in your `%LOCALAPPDATA%\Packages`, as
  an app's does until `rm`.

## Yours to do

- Commit and push (`src/container.zig` and this file are new). I read the Reproduce run,
  the `build (zig)` job first, for the fallback note.
- The tag `v0.103.0` is yours; I read the Release run after it.
