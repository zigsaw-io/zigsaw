# Iteration 92: Electron as a runtime

Started 2026-11-12, from "plan to add reusable Electron runtime". Iterations 67 and 68
packaged VSCodium with its own copy of Electron inside its image, and left "the shared
Electron runtime with draw.io" for later. Now `org.electronjs.Electron` is a runtime image,
Electron 44.11.2's own build for Windows, and draw.io 32.6.10 runs on it with only its own
files in its image. zigsaw is **0.92.0**: a runtime's `unsupported` carries over to the apps
on it, and every Start menu shortcut names its app's taskbar button. Two images are new, to
be published: the runtime and draw.io. How it's used is in
[recipes.md](recipes.md#apps-on-electrons-runtime), what was found in
[findings.md](findings.md#electron-as-a-runtime).

State at the start: 91 had landed (`2714984`, Reproduce 43140025948 and Release v0.91.0
43144289563 green). The upstream report had nothing about Electron.

## Outcome

- **`recipes/electron.json`**: Electron 44.11.2's zip, with Electron's own `ffmpeg.dll`
  without H.264 and AAC over the one with them, and zigsaw's module for apps on it. One
  eStargz layer of 158 MB (74 files), with the list of what draw.io's first start reads
  (14 files, 313 MB, `electron.exe` 247 MB of it). It asks for `soft`, and says why it can't
  run under the others. Run as an app, it's `electron`, for an app folder of your own.
- **`recipes/drawio.json`**: draw.io 32.6.10's portable zip, of which only
  `resources\app.asar` goes in its image (27 MB layer), with its icon. It runs
  `${electron}\electron.exe -r ${electron}\zigsaw\app.js ${app}\resources\app.asar`. It
  opens `.drawio`, `.vsdx`, `.mmd` and `.mermaid`, has a shortcut, its updater off
  (`DRAWIO_DISABLE_UPDATE`), and exports from the console (`drawio -x -f png ...`).
- **zigsaw's module** ([`recipes/electron/zigsaw-app.js`](../recipes/electron/zigsaw-app.js)),
  loaded before the app: the app is a packaged one (`app.isPackaged`), has the taskbar button
  `Zigsaw.<app id>`, and gets its arguments, a second start's too, as `electron <app>` gives
  them, without the module's own.
- **A runtime's `unsupported` is its apps'**: copied into the app's config as `uses` is, it
  makes a run told to use such a sandbox warn with the runtime's reason, `zigsaw info` show
  it, and a recipe that asks for such a sandbox fail to build.
- **Shortcuts name their app's taskbar button**, `System.AppUserModel.ID =
  Zigsaw.<app id>`, so a window that names the same is the shortcut's. Shortcuts made before
  0.92 get it from `zigsaw repair`, which `zigsaw upgrade` runs.
- **Same manifests in two fresh stores**: runtime `b427ce53`, draw.io `a2b433b2`.

## Decisions

Yours, in the planning dialog:

- **draw.io and a test app**, the test app as the second user of the runtime; VSCodium keeps
  its own Electron (43, where draw.io's is 44; its CLI runs Node through its program; it finds
  files next to that program).
- **Electron's program as Electron ships it**, its fuses unchanged, over turning off those
  draw.io's build turns off.
- **zigsaw's module plus a name in the shortcuts**, over the module alone or nothing.
- **Electron's `ffmpeg.dll` without H.264 and AAC**, so both images can be published, as
  ungoogled-chromium wasn't for its codecs.

Mine:

- **One image id for the runtime, tagged by Electron's version**; apps pin it by digest, and
  apps on one major version are kept on one image so they share it.
- **Through Electron's `default_app`** (`electron.exe <app>`) and a module given with `-r`,
  over a loader of zigsaw's own that would be the app `default_app` runs and load the real
  one: `default_app` is what every app's developers run theirs with.
- **The module takes `-r` and itself out of the app's arguments.** Without that, draw.io read
  its own `-r` (`--recursive`) and the module's path as a file.
- **`ELECTRON_FORCE_IS_PACKAGED` set by the module**, not by the runtime's `env`: an app's
  `env` can't take a variable away, and the runtime run as an app, for a folder in
  development, should stay as Electron runs one.
- **The runtime's layer eStargz, draw.io's gzip**: draw.io's own is one 64 MB file, which a
  lazy pull fetches whole.
- **draw.io's smoke check is `--version`** (it prints 32.6.10 through the runtime, the module
  and its own main module), over the export the plan had: it needs no files on the runner.
- **A shortcut's name for every app**, not only Electron's: another app started from its
  shortcut already counted as the shortcut's.

## What changed

| File | What |
|---|---|
| `recipes/electron.json`, `recipes/electron/zigsaw-app.js` (new) | the runtime and its module |
| `recipes/drawio.json` (new) | draw.io on it |
| `src/oci.zig` | `Runtime.unsupported`, `unsupportedUnder`, a recipe can't ask for a sandbox its runtime can't run under, tests |
| `src/deps.zig` | copies a runtime's `unsupported` into the app's config |
| `src/run.zig`, `src/info.zig` | the runtime's reason in the warning and in `info` |
| `src/shortcuts.zig` | `appUserModelId`, writes `System.AppUserModel.ID`, reads it back for a test |
| `src/win32.zig` | `IPropertyStore`, `PROPERTYKEY`, `PROPVARIANT`, `PKEY_AppUserModel_ID` |
| `tests/winwait.zig` | `--aumid`: a window's AppUserModelID |
| `tests/chromium.sh`, `tests/chromium/hello/` (new) | draw.io and the test app on the runtime |
| `tests/shims.sh`, `tests/upgrade.sh` | the shortcut's name, after `repair` and after an upgrade |
| `scripts/published-recipes.txt`, `scripts/published-groups.txt`, `scripts/upstream.txt` | the two images: published, in CI's `electron` group, checked upstream (OSV: `npm:electron`) |
| README, `docs/recipes.md`, `docs/findings.md`, `docs/gaps.md`, `docs/published-apps.md` | how, what was found, what stays open |
| `build.zig.zon`, `zigsaw.json` | 0.92.0 |

## Tests

`tests/chromium.sh` (not in CI; windows on the desktop), new rows, all on draw.io and a test app
([`tests/chromium/hello`](../tests/chromium/hello/)) whose recipe the suite writes, pinned to the
runtime it just built:

- draw.io opens a diagram given with `--file` (soft ok; low and AppContainer fail), its renderers
  are confined, a second run's diagram opens in a window of the first and the run ends;
- it exports a diagram to PNG from the console (`zigsaw run`, soft ok, the others fail) and
  through its `drawio` command;
- under low and in an AppContainer it says why, with the runtime's reason;
- its window and its shortcut name the same taskbar button, `Zigsaw.com.jgraph.drawio.desktop`;
- the test app is packaged, gets `[electron.exe, <app>, one]` with nothing of zigsaw's module,
  keeps its data in its volume, and has its own button, `Zigsaw.test.electron.hello`;
- both run one deployment of the runtime's layer, which `rm` of the test app leaves, and draw.io
  still exports after it;
- the runtime run as an app prints its version; draw.io gets the windowless shim, a shortcut and
  its four kinds of file; the real AppData (`draw.io`, `Zigsaw Hello`), profile and registry are
  untouched.

`tests/shims.sh`: the test app's shortcut names `Zigsaw.<id>`, and `repair` names it in a
shortcut made without one. `tests/upgrade.sh`: no name in the shortcut v0.80.0 and v0.83.0 make,
and the name after the upgrade. The unit tests: a runtime's `unsupported` (lookup, the build's
refusal, the config round trip, absent when there's none), and a shortcut written with the name
and read back.

| | result |
|---|---|
| unit tests | 221, and the other test programs' 12, 1 and 2, pass |
| `tests/chromium.sh` (store `E:\zs\i92\p`) | 38 ok, 1 skipped (`HKCU\Software\Chromium` was there before), 2 known gaps |
| `tests/shims.sh` | 57 ok |
| `tests/upgrade.sh` (from v0.80.0 and v0.83.0) | 32 ok |
| `tests/build.sh`, every group | base 113, zig 37, cmake-meson 21, langs 55: all ok |
| `tests/store.sh`, `tests/sandbox.sh`, `tests/self.sh` | 17, 142, 20 ok |
| the v0.91.0 release | pulls draw.io from a local zot and runs it (`--version`, exit 0); under low exits 3 without a reason, which 0.92 gives on the same store |
| the package | `zigsaw.exe` `13094c16`, 0.92.0; Defender finds nothing in its six programs, nor in the runtime's `electron.exe` |

## What it costs, and saves

| | download | on disk |
|---|---|---|
| Electron's runtime (74 files, eStargz) | 158 MB | 367 MiB |
| draw.io's own (`app.asar` and its icon, gzip) | 27 MB | 62 MiB |
| draw.io's zip as upstream ships it | 180 MB | 450 MB |

Pulling draw.io downloads 177 MiB: the runtime and its own layer. A second app that pins the same
runtime downloads its own layer only, and adds its own files to the disk. Building the runtime
took 26 to 34 s here, draw.io 5 to 10 s; the runtime's list (`prefetch`) is 14 files, 313 MB,
`electron.exe` 247 MB of it, which a lazy pull fetches whole.

## What I got wrong on the way

- **`-r` shows in the app's arguments.** The first probe gave the app
  `[electron.exe, -r, <module>, <app>, ...]`; draw.io would have read `-r` as its own
  `--recursive`. The module now takes itself out.
- **A second start's arguments have Chromium's switches between `-r` and the module**, so taking
  out the two as a pair missed them; the module now looks for its own path, then the `-r` before.
- **My first handover was sent 3 s after draw.io's window showed**: nothing opened, and the window
  ignored a close until later. Sent after draw.io settles, it works; the suite waits 5 s.
- **My test app's `app.addRecentDocument` wrote your real Recent folder**, a jump list and Quick
  access. I took out what it added (the two `.lnk` files, the jump list, the Quick access entry),
  and the suite's test app doesn't add any. Looking for it after the suite's runs showed more:
  VSCodium's files and work folders and Chromium's download from every `chromium.sh` run since
  iteration 67, which the suite's check never looked at. I removed the seven from today's runs;
  the suite now removes those that point into its folder. Their names stay in Explorer's
  `RecentDocs` list in HKCU, whose order is a binary value I didn't edit.
- **Two test rows tested the wrong thing on their first run**: the runtime's layer was read as the
  last digest in its manifest, which for eStargz is its table of contents'; and a shortcut "made
  by an older zigsaw" was `CreateShortcut` on the existing file, which keeps its properties.

## Not checked

- **Pinning a draw.io window to the taskbar**, and starting it from the pin: it takes your hands.
  The window and the shortcut name the same button, which is what Windows goes by.
- **Notifications** of an app on the runtime: draw.io shows none.
- **Another app on the runtime than the test app**: none with a Windows zip was looked for, as you
  chose. One with `extraResources` or native modules would need more (recipes.md says what).
- **CI**: the two images are built and compared, and `--version` run, in the `electron` group on a
  runner for the first time after you publish them; `chromium.sh` isn't in CI.
- **A lazy pull of draw.io from ghcr.io**, measured once it's published.
- **`tests/published.sh` here**: the two images aren't on ghcr.io yet, so its comparison would
  fail; their smoke check (`--version`) was run by hand.
- **`tests/chromium.sh`'s new last step**, removing its Recent shortcuts, was added after its
  second full run; it ran on its own (on today's leftovers, then on a folder with none), not at
  the end of a run.

## Yours to do

1. Publish before pushing, the runtime first, and make both packages public:
   `ZIGSAW_HOME='E:\zs\i92\p' ZIGSAW='E:\zs\i92\bin92\zigsaw.exe' scripts/publish.sh electron.json drawio.json`
2. Commit (new: `recipes/electron.json`, `recipes/electron/`, `recipes/drawio.json`,
   `tests/chromium/hello/`, `docs/iteration-92.md`) and push. I read the Reproduce run: the
   `electron` group, the build groups and the pins job first.
3. The tag `v0.92.0` is yours; I read the Release run after it.
4. When you have a minute at the desktop: pull draw.io into your own store, start it from the
   Start menu, pin its window, close it, and start it from the pin.
5. VSCodium's `ffmpeg.dll` is the one with H.264 and AAC ([findings](findings.md#electron-as-a-runtime)):
   whether to swap in Electron's other one, a recipe change and a republish, is your call.
6. Your Recent folder still has 14 shortcuts from earlier test runs (iterations 17 to 68:
   `tmp.*` folders under `D:\zs\i67\tmp` and `D:\zs\i68\tmp`, `zigsaw-doc.pdf`,
   `zigsaw-tone.wav`, `zigsaw-downloaded.txt`). I can remove them on your yes;
   `zigsaw-draft.7z` there points into the repository, and may be yours.
