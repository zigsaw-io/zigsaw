# Iteration 68: Apps reach out

Built 2026-11-03. An app can now reach your other apps' commands and your own
programs when it's allowed to, take links from other programs, and say why it
can't run under a sandbox instead of exiting with code 3. Planning also found
that iteration 67 got something wrong, which this fixes. zigsaw **0.68.0**. Two
images to publish, VSCodium and Kanboard. Findings are in
[findings.md](findings.md#links-and-what-runs-reach), what a recipe needs in
[recipes.md](recipes.md#sandbox).

## Outcome

- **Iteration 67 was wrong that VSCodium leaves nothing else outside.** On every
  start under `soft`, it wrote the real `HKCU\Software\Classes\vscodium`, naming its
  program in the deployment, so a link started it with no zigsaw in the way, in
  your real environment, with its data outside the app's. It went stale on update,
  and `zigsaw rm` left it. The published image does this to everyone who has run
  it. The recipe now takes that call out, zigsaw registers the scheme itself, and
  installing the new image takes such a key over.
- **`--share=commands`**: the store's commands on a `soft` run's PATH, after the
  system's, each running as its own app, with its own data and sandbox.
  VSCodium's terminal runs another app's command, and that app sees its own home.
- **`--share=host`, and `zigsaw-host`**: a program from your own PATH, in your real
  environment, with the run's rights: at low integrity in a low run, and ending with
  the run. Nothing crosses a boundary, unlike `flatpak-spawn --host`.
- **URL schemes**: `"schemes"` in a recipe. A free scheme opens with the app, through
  a shim that takes one argument of that scheme and otherwise starts nothing. One
  something else has stays as it is, and the app is only offered. A
  `vscodium://file/` link followed by Windows opens the file in VSCodium through
  zigsaw, and `rm` takes every key back out.
- **`permissions.unsupported`**: an image says which sandboxes it can't use, and
  why. A run under one warns first, as does saving the override, and a GUI shim's
  message box shows it when the run fails.
- **What isn't known: whether Settings lists an app for `http`.** Writing the keys
  and leaving the default alone are verified. Windows' API for that list doesn't
  show the app, and doesn't show it with a copy of Firefox's keys either, so it
  can't say. See [Not checked](#not-checked).

## Starting decisions

From the plan:

- Yours: **`commands` + `zigsaw-host`**, with no real PATH in runs, and **custom
  schemes registered, http/https offered**.
- Mine: `unsupported` warns rather than refuses, before the run, as
  `--no-sandbox` is a documented path and Kanboard at low doesn't exit with an error;
  VSCodium's image declares `commands` and `host`, which widen nothing under `soft`
  and show in its consent line; both count as added access, and schemes don't, as
  associations don't; the store's `bin` goes after the system's on PATH; a scheme
  someone else has is never overwritten, by a general rule with no list of names; a
  key with no owner that names this store's `deploy\` counts as ours, to heal what
  the published image wrote.

Decided during (mine):

- **`commands` is for `soft` only.** The plan's gate: a zigsaw at low integrity can't
  open the store at all (`error: AccessDenied`). A low or AppContainer run doesn't get
  the directory, and says so.
- **A nested zigsaw takes your variables back first.** A command started from a run
  is a zigsaw with that run's environment, so it found the first app's home as your
  profile: your folders came back missing, and that home read-only. It's one fix, at
  the start of `main`, on seeing `ZIGSAW_ID`, and `zigsaw-host` uses the same call.
- **`zigsaw-host` stays in its own directory** (`<store>\host`), so that having it on
  PATH brings nothing else, and its name is fixed, unlike the relay's.
- **Links run through their own shims, in `open\<app>\urls`**, as a shim's name is
  its export's, and a file type's shim for the same export is another shim.
- **A scheme's arguments are an export's**, as `Export.args` exists: VSCodium gets a
  `codium-url` command, and Chromium a `chromium-url`. My plan had first said exports
  had no arguments, which was wrong.
- **VSCodium's own question stays on**, before a link opens a local file. Only the
  test's settings answer it.
- **Tests went in a new `tests/reach.sh`**, not `tests/shims.sh` as planned: it's its
  own subject, and takes 30 s.

## What was built

- `src/host.zig` (`zigsaw-host.exe`, 143 KB, with VERSIONINFO), in `build.zig`,
  `scripts/package.sh`, `scripts/install.ps1`.
- `src/oci.zig`: `Permissions.unsupported`, `.commands`, `.host` (all absent unless
  set, so digests stay), `Scheme`, `AppConfig.schemes`, `isValidScheme`.
- `src/associations.zig`: schemes, Default apps' keys, `removeStale`, `repair`.
- `src/Sidecar.zig`, `src/shim.zig`: `schemes`, `hasScheme`, `oneUrl`.
- `src/environment.zig`: `path_after`, `restoreUser`. `src/process.zig`:
  `userEnvironmentBlock`.
- `src/run.zig`: `warnUnsupported`, `sharedPath`, `hostDir`. `src/override.zig`,
  `src/main.zig`: `--share=commands|host`, the warning on saving an override.
- `src/info.zig`, `src/catalog.zig`, `src/builder.zig`, `src/recipe.zig`: schemes,
  `can't run`.
- `recipes/vscodium.json` (manifest 47455498, layer a14108dd),
  `recipes/kanboard.json` (manifest 9f60f14c, layer 4b393eb0 as published),
  `recipes/no-publish/ungoogled-chromium.json`, `recipes/no-publish/files.json`.
- `tests/reach.sh` + `tests/reach/` (new, in CI's `suites` job), `tests/chromium.sh`.
- README, docs/findings.md, docs/recipes.md, docs/how-it-works.md, docs/gaps.md,
  docs/published-apps.md.

## Results

- `tests/reach.sh`: 33 ok, 0 failed, 26 s.
- `tests/chromium.sh`: 28 rows, 0 failed, 2 known gaps as before, 94 s. Its registry
  row now compares the keys of `HKCU\Software\Classes`, `RegisteredApplications`,
  `Clients\StartMenuInternet` and `Run` before and after, with VSCodium run many
  times: nothing new.
- `zig build test` passes. `tests/shims.sh` 55, `tests/sandbox.sh` 124,
  `tests/store.sh` 16, `tests/batch.sh` 12, `tests/install.sh` 17, `tests/registry.sh`
  102, all ok; `tests/matrix.sh` 0 differ, with 3 known gaps; `tests/self.sh` 17 ok,
  so zigsaw still builds itself byte-identical.
- The same manifests in `D:\zs\i68\p` and `D:\zs\i68\p2`: VSCodium 47455498 and
  Kanboard 9f60f14c.
- Defender: `zigsaw.exe`, `zigsaw-host.exe` and VSCodium's deployment clean. As
  [before](findings.md#other-findings), this machine allows `Bearfoos.A!ml`, so that
  can't show that one.
- check-pins: 0 missing, the 4 llvm-mingw warnings as before. VSCodium's and Kanboard's
  new manifests aren't pins of anything.

The first version of two link rows passed for the wrong reason: VSCodium restored the
file from its last session, and no link had opened anything. The row through Windows
showed that, as it stopped at VSCodium's own question. Each now opens a file the editor
has never seen.

## Not checked

- **Whether Settings' Default apps lists an app for `http`, and whether choosing it
  works.** It takes looking at the page; Settings was open here, and I left it alone.
- **A runner**: `tests/reach.sh` runs on Windows Server 2025 for the first time with
  your push, and with it a real private scheme and `ShellExecute` there.
- **A sign-in that comes back through a link**, only links that open files.
- **Typing in VSCodium's terminal by hand**, or a `zigsaw-host` terminal profile: the
  rows run a task. An extension's own lookup of a tool through `commands` follows from
  the extension host's PATH, and wasn't run with a real extension.
- **Installing the published `4c45eaf4` over a real key and updating**: the takeover is
  tested with a key written to look the same, in a scratch key.

## On this machine

- `HKCU\Software\Classes\vscodium`, naming `D:\zs\i67\p`, was left by my iteration 67
  runs, and a `vscodium://` link here would have started that test copy. It's removed;
  the key's copy is `D:\zs\i68\out\HKCU-Classes-vscodium-before-cleanup.reg`.
- `tests/chromium.sh` and `tests/reach.sh` write a private scheme into your real
  `HKCU\Software\Classes` and `RegisteredApplications` for a moment; `zigsaw rm` takes
  them out, and each suite checks that.
- `D:\zs\i67\s` and `s2` (5 GB), iteration 67's probe stores, could go: D: has 11 GB
  free. The permission check stopped me deleting them, so they're yours to remove.

## Next

- **Publish before pushing**, from the store that built them:
  `ZIGSAW_HOME='D:\zs\i68\p' ZIGSAW='D:\zs\i68\bin\zigsaw.exe' scripts/publish.sh vscodium.json kanboard.json`
- Then commit and push (`git add --chmod=+x tests/reach.sh`), and I read the Reproduce
  run, with `tests/reach.sh`'s first run on a runner.
- Tag **v0.68.0** after the push, and I read the Release run: its zip has
  `zigsaw-host.exe` now.
- Later: if Settings doesn't list it, `Clients\StartMenuInternet` for browsers, or a
  known gap; `Clients\Mail` for `mailto`; a shim's message for a link it refused from a
  console shim, which closes at once; the Electron runtime with draw.io; a `commands`
  that works at low, which would take zigsaw at low being able to use the store.
