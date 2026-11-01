# Iteration 67: Chromium and Electron

Built 2026-11-01. VSCodium and ungoogled-chromium run from zigsaw, under
`soft`, with Chromium's own sandbox whole. They were the largest kind of Windows
app not yet tried, and they bring a sandbox of their own. zigsaw's code doesn't
change: still **0.66.0**, nothing to tag. One image to publish, VSCodium.
Findings are in [findings.md](findings.md#chromium-and-electron), what a recipe
needs in [recipes.md](recipes.md#chromium-and-electron).

## Outcome

- **Chromium's sandbox can't start at low integrity or in an AppContainer**,
  and that's Windows, not zigsaw. It starts by making a window station, which
  Windows refuses both, and then stops itself: exit code 3, no window, no log.
  The same happens at low integrity with no zigsaw in the way. In `chrome.dll`,
  the only switch that skips the check is `no-sandbox`.
- **Under `soft`, all of it works**, and Windows confirms the confinement:
  renderers at untrusted integrity with restricted tokens, the GPU process
  restricted, nothing told `--no-sandbox`.
  - ungoogled-chromium: pages, https, WebGL on the real GPU (D3D11), H.264,
    tabs handed to the running instance, Save As.
  - VSCodium: its terminal, git from MinGit, an extension from Open VSX in 4 s,
    an extension saving a file, its CLI.
- **They leave nothing outside.** Chromium's `HKCU\Software\Chromium` is kept
  with its data, through iteration 19's `registry`; `.vscode-oss\cli` stopped
  appearing when the recipe left out `bin\codium-tunnel.exe`.
- **Reproducible**: the same manifests from two fresh stores.
- **What zigsaw doesn't give them is confinement.** `pull` and `info` say so
  ("whatever you can write"). They get separate data, pinned installs and clean
  removal.

## Starting decisions

From the plan and its checkpoint, the same day:

- Yours: **VSCodium and ungoogled-chromium** (the shared Electron runtime and
  draw.io not this time); the sandbox decided **after the findings**, with the
  table in front of you.
- Yours, at the checkpoint: **ungoogled-chromium under `soft`, in
  `recipes/no-publish/`**, as its build has codecs patents cover; **VSCodium
  under `soft`, with `--sandbox=low ... --no-sandbox` documented** for those who'd
  rather confine its extensions and terminal. No image passes `--no-sandbox`.
- Mine: the ids (Flathub's); both from upstream's zips; MinGit as VSCodium's
  runtime; eStargz if real upgrades copy at least 30%.

Decided during (mine):

- **VSCodium is on eStargz, though only one of two upgrades reached 30%.**
  1.143.17183 → 17232, a recovery release, copies 83.5% (182 MB not fetched);
  1.140 → 1.143, a monthly one, copies 24.6% (54 MB), under the bar I'd set. Both
  save real downloads, and the layer's cost is small. ungoogled-chromium stays
  gzip: nothing pulls it.
- **`codium` is the GUI program, `codium-cli` the batch file.** Through its own
  CLI, `codium <folder>` closed the editor within a second: the CLI starts the
  GUI detached and exits, and the run's job ends what's left. The GUI program
  takes the same files and folders through the windowless shim. So zigsaw needn't
  change how a run ends.
- **VSCodium's `updateUrl` is deleted from its `product.json`**: it logs that
  updates are off, and shows no warning, as that file isn't among the ones it
  checks. That takes a build step, so the recipe has BusyBox as an SDK.
- **Chromium's permissions name `desktop` and `documents`** as well as
  `downloads`. Without `documents`, Windows' Save As dialog said "Location is not
  available" each time. Under `soft`, they're links, not rights.

## What was built

- `recipes/vscodium.json` (`com.vscodium.codium`, manifest 4c45eaf4, layer
  42bb17c4, 218 MB, 623 MB deployed).
- `recipes/no-publish/ungoogled-chromium.json`
  (`io.github.ungoogled_software.ungoogled_chromium`, manifest d7d6227a, layer
  eda3e9f4, 192 MB, 443 MB deployed).
- `tests/procprobe.zig` (`zig build procprobe`): how a process and its
  descendants are confined, as Windows says.
- `tests/acprobe.zig`: `window-station` and `desktop` rows.
- `tests/winwait.zig`: `--dismiss`, which closes a dialog and doesn't wait.
- `tests/chromium.sh` (new, local) and `tests/chromium/saver`, a small extension
  that edits and saves a file through VS Code's API, as nothing else proves the
  editor's own save without keystrokes.
- `scripts/published-recipes.txt`, `scripts/published-groups.txt` (group
  `electron`), `tests/published.sh` (VSCodium in `stays_up_ids`).
- README, docs/findings.md, docs/recipes.md, docs/published-apps.md,
  docs/gaps.md, docs/layer-formats.md.

## Results

- `tests/chromium.sh`: 21 rows, 0 failed, 2 known gaps (VSCodium with
  `--no-sandbox` and `codium-cli --version`, both in an AppContainer), 63 s, on
  three consecutive runs.
- zigsaw's unit tests: `src/` unchanged, cached as passing.
- The same manifests in `D:\zs\i67\p` and `D:\zs\i67\p2`.
- Defender: both deployments and `zigsaw-procprobe.exe` clean.
- check-pins: VSCodium missing until it's published (expected), 4 older runtimes
  as before.

Not checked:

- **A runner**: VSCodium's `stays_up` row on Windows Server 2025 runs for the
  first time with your push. Nothing else of it has run there.
- **Typing and saving by hand** in VSCodium. My one attempt with simulated keys
  didn't reach the editor, hence the saver extension.
- A user name long enough for VSCodium to reach `MAX_PATH`, and sign-ins that
  come back through a link.

## On this machine

My first `soft` runs left `HKCU\Software\Chromium` and an empty
`C:\Users\Test\.vscode-oss\cli`, before any recipe kept them, as I hadn't checked
beforehand. Timestamps match those runs, and the key names this build. Both are
removed; the key's copy is `D:\zs\i67\out\HKCU-Software-Chromium-before-cleanup.reg`.

## Next

- **Publish VSCodium before pushing**, from the store that built it:
  `ZIGSAW_HOME='D:\zs\i67\p' ZIGSAW='D:\zs\i67\bin\zigsaw.exe' scripts/publish.sh vscodium.json`
- Then commit and push, and I read the Reproduce run. It'll be a long one:
  the published lists changed, so GTK's, Qt's, TeX Live's and GDAL's groups are
  checked too.
- No tag: zigsaw's version hasn't moved.
- Later: a terminal that can reach your tools (VSCodium's PATH has only its own
  and Windows'; like `flatpak-spawn --host`); URL schemes; a message when an image
  that can't start under a sandbox is told to; the Electron runtime with draw.io.
