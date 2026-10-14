# Iteration 19: finding apps, and registry settings kept with the app

Concluded 2026-10-15.

## Outcome

- **Finding apps**: a catalog of the apps a registry has, published next to
  their images (`ghcr.io/zigsaw-io/catalog`), and `zigsaw search` to find
  them by any word in their id, name, summary, commands, shortcuts or the
  kinds of file they open.
- **`zigsaw info`** shows what an app is, needs and may reach, from its image
  in the registry, before it's installed; **`pull`** says what the app may
  reach before downloading it, and **`update`** when that changes.
- **Apps describe themselves**: recipes get `name`, `summary`, `homepage` and
  `license`, set on the 15 published apps no other recipe pins.
- **Registry settings kept with the app**: a recipe declares the keys its
  app keeps in `HKEY_CURRENT_USER`; zigsaw keeps them in the app's data, and
  puts them there for its runs, where low integrity and an AppContainer may
  write them too. 7-Zip now saves its settings in every sandbox.
- **The v0.18.0 release, checked**: it installs, and its programs are those
  of the release notes; but they were built for the CPU of GitHub's runner,
  so they can't be rebuilt anywhere else, and may not run on older CPUs.
  From 0.19.0, zigsaw is built for the x86-64 baseline.
- **VLC's flaky row** in `tests/guiapps.sh`: VLC sometimes starts playing
  30 s late; the suite waits for it now.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-19-parallel-adleman.md`). v0.18.0 was released, and
the six images iteration 18 changed were on ghcr.io with its digests.

- Scope, your picks: **finding apps** and **registry isolation**, with the
  release check and VLC's flaky row. Not this time: publishing from CI,
  offline bundles, GTK in CI.
- **Names and summaries in the images**, set now on the apps no recipe pins
  (the ones people install), over all 27 images (recipes pin runtimes and
  SDKs by digest, so all would be rebuilt and republished) or a text file of
  the catalog's own.
- **Registry**: you asked to probe two approaches, copying an app's keys in
  and out of HKCU around its runs, and redirecting them inside its process;
  the plan went ahead with the first only.
- Mine, approved with the plan: the catalog at `<registry>/catalog:latest`,
  made by `push --catalog` from what the registry has, the id `catalog`
  refused; the standard OCI annotations from the new fields; `pull` and
  `update` tell, without asking; `registry` a field of its own, not a
  permission; version 0.19.0.

## What was built

### The release check, and a baseline CPU

- `irm | iex` from the `v0.18.0` download URL and from `latest`, into scratch
  directories (`ZIGSAW_INSTALL_DIR`, `ZIGSAW_INSTALL_NO_PATH`, and a scratch
  `ZIGSAW_HOME`, without which `repair` would have repointed your real store's
  shims): 0.18.0, the three programs' SHA-256 as in the release notes, PATH
  untouched; it pulled and ran BusyBox and zig; `-Uninstall` removed both.
- A build of the tag here didn't give the release's bytes (see
  [findings](findings.md#other-findings)): `build.zig` set only the
  target's OS, so the CPU was the builder's.
  [`build.zig`](../build.zig) now targets `x86_64` with the baseline CPU;
  a unit test checks zigsaw is built for it.
- `install.ps1 -Uninstall` named "the folder above" the install directory
  as the store, which `-Dir` can make untrue; it names the store zigsaw uses.

### Registry settings kept with the app

- [`src/hkcu.zig`](../src/hkcu.zig) (new): a run's keys, in and out of HKCU.
  The first run copies the hive's keys into HKCU, after copying a key of
  the same name aside; each run labels the keys low, or grants them to the
  app's capability, as its sandbox needs; the last run to end (the one that
  can lock `<data>.hkcu.lock` exclusively) copies them back into the hive,
  deletes them, and puts back what was aside. Each step is recorded in
  `HKCU\Software\zigsaw\keys` before the next, so that the next run,
  `repair` or `rm` settles what a run that didn't end left, keeping both
  the app's settings and those aside. A named mutex makes zigsaw processes
  take turns. A key another app's run is using makes the run fail.
- [`src/regkey.zig`](../src/regkey.zig) (new): the registry key helper,
  moved from `associations.zig`, with a copy value by value, since
  `RegCopyTree` can't write into a hive `RegLoadAppKey` loaded.
- [`src/acl.zig`](../src/acl.zig): a key's low label and capability grant.
- [`src/oci.zig`](../src/oci.zig), [`src/recipe.zig`](../src/recipe.zig):
  `registry`, keys below `Software`, not Windows' own; `run.zig` around the
  app's process; `rm` and `repair` settle leftovers; `list` says
  `(keeps HKCU\...)`.
- [`recipes/7zip.json`](../recipes/7zip.json): `"registry": ["Software\\7-Zip"]`.

### Finding apps

- [`src/catalog.zig`](../src/catalog.zig) (new): the catalog's format (each
  app's id, version, manifest, download size, name, summary, homepage,
  licence, commands, shortcuts, kinds of file, permissions, registry keys and
  runtimes), `push --catalog` (from each app's `latest` tag in the registry),
  reading it with a copy in `cache\catalog\` (used again while the registry's
  is the same, and when the registry can't be reached), and `search`.
- [`src/info.zig`](../src/info.zig) (new): `zigsaw info`.
- [`src/remote.zig`](../src/remote.zig): an image's manifest and config
  without its layers (`fetchInfo`); `pull` tells what the app is and may
  reach before the layers; `update` tells when that changed.
- [`src/oci.zig`](../src/oci.zig): `name`, `summary`, `homepage` and
  `license`, left out of configs that don't have them; permissions in words
  ("the network; your Desktop, Downloads and Videos"); the id `catalog`
  refused. [`src/builder.zig`](../src/builder.zig): the matching annotations.
- [`scripts/publish.sh`](../scripts/publish.sh) pushes the catalog of every
  published app after the images; [`tests/published.sh`](../tests/published.sh)
  checks it lists the published versions.
- The 15 recipes: MinGit, Prettier, Python, SQLite, ripgrep, bat, fzf, zot,
  zstd, Text Editor, Rnote, 7-Zip, Notepad++, SumatraPDF and VLC.

### Tests

- Unit tests: registry keys, metadata, permissions in words, the catalog's
  JSON and search's ranking, a key copy value by value, the baseline CPU.
- [`tests/regprobe.zig`](../tests/regprobe.zig) (new, `zig build regprobe`):
  the probe, kept like `acprobe` and `hostprobe`.
- [`tests/sandbox.sh`](../tests/sandbox.sh): 8 checks with two BusyBox apps
  keeping one key, written by `reg.exe` in their runs: values kept from run to
  run in each sandbox, HKCU empty between runs, `--ephemeral`, a key moved
  aside and back, a killed run settled by the next, two apps, `rm`.
- [`tests/registry.sh`](../tests/registry.sh): 11 checks: `push --catalog`,
  `search` by words, commands and kinds of file, no match, `info` of an app in
  the catalog and of any image, `pull` telling first, the cached catalog with
  the registry unreachable, the id `catalog`.
- [`tests/guiapps.sh`](../tests/guiapps.sh): "7-Zip keeps its settings with
  its data, and in HKCU only while it runs" replaces "leaves the real
  registry alone", ok in all three sandboxes; VLC's row waits up to 60 s, with
  a 60 s clip, and every row waits for zigsaw to end rather than a second.

### Code map

| File | Change |
|---|---|
| `src/hkcu.zig`, `src/regkey.zig` (new) | registry keys kept with the app |
| `src/catalog.zig`, `src/info.zig` (new) | the catalog, `search`, `info` |
| `src/oci.zig`, `src/recipe.zig`, `src/builder.zig` | `registry`, `name`, `summary`, `homepage`, `license`, annotations, permissions in words |
| `src/run.zig`, `src/main.zig`, `src/acl.zig`, `src/associations.zig`, `src/appcontainer.zig`, `src/Store.zig`, `src/win32.zig` | keys in and out of HKCU, commands, labels and grants of keys |
| `src/remote.zig`, `src/install.zig`, `src/update.zig` | `fetchInfo`, telling before downloading |
| `build.zig`, `build.zig.zon` | the baseline CPU, `regprobe`, version 0.19.0 |
| `scripts/install.ps1`, `scripts/publish.sh` | uninstall message, version; the catalog |
| 15 recipes | name, summary, homepage, licence; 7-Zip's `registry` |
| `tests/regprobe.zig`, `tests/regprobe/app.json` (new), `tests/sandbox.sh`, `tests/registry.sh`, `tests/guiapps.sh`, `tests/published.sh` | the checks above |
| `README.md`, `docs/findings.md`, `docs/gaps.md` | finding apps, registry settings, releases, findings, gaps |

## Results

### Tests

- Unit tests: 92 pass (84 before).
- `tests/sandbox.sh`: 78 pass, 8 of them new (14 s), and HKCU had neither
  the test key nor `Software\zigsaw` afterwards.
- `tests/registry.sh`: 59 pass, 11 of them new (44 s, with zot).
- `tests/guiapps.sh`: 15, all as intended (one known gap), in its last 5
  runs, 2 of them while store `b` was building; 7-Zip's row ok in all three
  sandboxes. Before the change to VLC's row, its first run of the day failed
  it under `soft` and `appcontainer` (no window named the clip within 15 s).
- `tests/install.sh` 16, `tests/shims.sh` 54, `tests/store.sh` 15: all pass.
- `tests/matrix.sh`: as intended, three known gaps (104 s).
- `tests/build.sh`, `tests/published.sh`, `tests/gtk.sh` weren't run: builds
  change only for recipes with the new fields, which the 15 builds below
  cover; CI runs the first two, and `published.sh` needs the catalog
  published.
- By hand, with a local zot: the 13 apps outside GTK pushed from store `a`,
  their catalog, and `search` and `info` from an empty store; the README's
  `zigsaw search pdf` is that output.

### Reproducibility

| Image | Manifest | Was |
|---|---|---|
| `org.git_scm.MinGit` 2.56.0.windows.1 | `636d59bc` | `2b2e3619` |
| `org.python.python` 3.14.7 | `cdbdab8d` | `e8fbdc15` |
| `io.prettier.prettier` 3.9.9 | `32b02c26` | `6b971b88` |
| `org.sqlite.sqlite3` 3.53.4 | `59232683` | `18390935` |
| `com.github.facebook.zstd` 1.5.7 | `2eb945af` | `5714b0d2` |
| `com.github.junegunn.fzf` 0.74.4 | `1b5ab40f` | `bf628217` |
| `dev.zotregistry.zot` 2.1.21 | `6e69f740` | `135f8114` |
| `com.github.BurntSushi.ripgrep` 15.2.0 | `86e8366a` | `168eb109` |
| `com.github.sharkdp.bat` 0.26.1 | `aad1890f` | `1eaeaa55` |
| `org.7_zip.7zip` 26.04 | `0f4644b7` | `9ba65a93` |
| `org.notepad_plus_plus.NotepadPlusPlus` 8.9.8.1 | `19274b8a` | `9966f0e9` |
| `org.sumatrapdfreader.SumatraPDF` 3.6.1 | `2f76253c` | `90f00fc5` |
| `org.videolan.VLC` 3.0.24 | `9b15a00a` | `c1e9cc23` |
| `org.gnome.TextEditor` 51.0 | `0dfce4f5` | `7bc27324` |
| `com.github.flxzt.rnote` 0.14.2 | `df74c962` | `93391da1` |

The same from `D:\zs\a` and `D:\zs\b`, built by the same zigsaw 0.19.0. Only
their configs (and so their manifests) changed: each layer is the one on
ghcr.io already, so publishing them uploads a config and a manifest each,
and the catalog. No other image changes. Rnote took 20 to 21 minutes to
build in each store, Text Editor 2, bat 3.5.

## Decisions made along the way

- **A key is copied value by value**, not with `RegCopyTree`, which can't
  write into a hive `RegLoadAppKey` loaded (probe).
- **The runs of an app are counted with a lock file next to its data
  directory**, shared by each run and taken exclusively by the last, rather
  than files inside the data directory, which the app may write.
- **The keys are recorded in HKCU**, not in a store, so that two stores'
  copies of an app don't use a key at once.
- **`build.zig` targets the x86-64 baseline**, for every build, so that the
  programs tests run are the ones released (a native build costs 3% on a
  pull).
- **VLC's flaky row is fixed in the test**: the app sometimes starts
  playing 30 s late, which a user would see too, but the cause wasn't found.

## Findings

See [findings.md](findings.md#the-registry) and
[findings.md](findings.md#other-findings). Besides:

- Unit test output that a test writes to stderr makes `zig build test` print
  "failed command" though every test passed.

## Known gaps

- An app's keys are in the real HKCU while it runs; a copy of the app
  installed the usual way, running meanwhile, shares them.
- Only the keys an image declares are kept apart; no override adds one.
- In an AppContainer, making two missing levels of keys at once from HKCU
  fails.
- The catalog is the default registry's only, as `publish.sh` last made it;
  runtimes and SDKs have no names yet.
- v0.18.0's programs need AVX2, BMI2 and the SHA instructions.
- VLC's late start, cause unknown.

## Suggested for iteration 20

- You publish the 15 images and the catalog (and make the `catalog` package
  public), push, and tag `v0.19.0`; then the release check, this time
  comparing the programs with a local build byte for byte.
- `zigsaw search` against ghcr.io, and the README's example of it.
- Names for the runtimes and SDKs, at their next versions.
- GTK in CI, still.
