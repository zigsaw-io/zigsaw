# Iteration 6: C for every build, commands from runs, suites in CI

Concluded 2026-10-03.

## Outcome

Iteration 5 made building from source practical, but left three gaps. Builds
had zig's C compiler only as `zig cc`, so Rust crates that compile C found
none, and most Rust tools beyond ripgrep have such crates. Commands that an
app installs while it runs, such as `tsc` after `npm install -g typescript`,
weren't on PATH, the oldest friction for Node users. And CI checked only that
the published recipes reproduce; the end-to-end suites ran on one machine,
sometimes not at all. Zigsaw now:

- **gives builds a C toolchain by its usual names**: zig's image aliases
  `cc`, `c++`, `ar`, `ranlib` and `rc`, and sets what the cc crate needs to
  use them. bat is built from source, with its C libraries (oniguruma,
  libgit2, zlib), and reproduces;
- **puts commands that runs install on PATH**: after each run, the commands
  in the app's PATH directories in its data directory get shims, as exports
  do. `npm install -g` and `cargo install` work by name;
- **keeps sources next to images**: `push --sources` stores the files an
  image was built from in its registry repository, and a build whose pinned
  download fails takes them from there. This came in when BusyBox's only
  download site began refusing everyone;
- **runs every end-to-end suite in CI**, after the reproducibility check, on
  the same runner.

All ten published images, bat included, have the digests of fresh builds of
their recipes, and their sources next to them on ghcr.io.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Scope | Two themes: wider builds, and commands from runs plus CI. Of the toolchains, only zig's C aliases, with bat built from source as the proof. CMake + Ninja and Go wait |
| Commands from runs | Scan the app's (and its runtimes') PATH entries in `${data}` after every run that isn't `--ephemeral`, and on install and update. No new config field. Rust's recipe keeps cargo's home in `${data}`, so `cargo install` works the same way |
| CI | The same job as the reproducibility check, reusing its build store: one step per suite, `registry.sh` against zot |

Decided during the iteration:

| Decision | Choice |
|---|---|
| The cc crate's settings (slice 2) | In zig's image `env`, like `ZIG_GLOBAL_CACHE_DIR`, so Rust recipes need only zig in their SDK. Chosen over a new build-only config field, and over setting them in each recipe |
| Sources whose upstream is gone (slice 3) | A source mirror in the registry: the pinned files kept next to each image, and builds falling back to them. Chosen over mirror URLs in recipes, and over waiting for frippery.org |
| Known AppContainer gaps in CI (after slice 3) | The matrix marks them `gap`: shown, but not failing the run, so CI fails only when a result changes |

The decisions of iterations 1–5 still hold.

## What was built

The iteration ran as three slices, each ending in working, tested code.

1. **Commands installed at run time.**
   - An app's command directories are its PATH entries in `${data}`, and
     its runtimes'. A command is an `.exe`, `.com`, `.cmd` or `.bat` file
     directly in one; its name is the file name without the extension.
   - One sync makes the app's shims match its exports plus those commands.
     It runs on install, and after each run that isn't `--ephemeral`, where
     it reports only changes and only warns on failure. Exports win over a
     command of the same name; another app's name is left to it.
   - Shims change under a new `bin.lock`. `rm` holds it until the app's ref
     is gone, so a run ending at the same time can't bring its shims back.
   - `recipes/rust.json` sets `CARGO_HOME=${data}\cargo` and puts
     `${data}\cargo\bin` on PATH.
   - Export and alias names may contain `+`.
2. **zig's C aliases, and bat from source.**
   - A probe first, in a store at a short path: each alias in a BusyBox
     build; the cc crate through the aliases; bat with its default features;
     bat in two stores and with a warm cache. It found that BusyBox's `ar`
     ran instead of zig's, that the cc crate needs settings, and that the
     aliases must name the target (see Findings).
   - `recipes/zig.json` aliases `cc` and `c++` (both with
     `-target x86_64-windows-gnu`), `ar`, `ranlib` and `rc`, and sets the
     cc crate's variables for `x86_64-pc-windows-gnu`.
   - Builds set `BB_OVERRIDE_APPLETS` to their aliases' names, so aliases
     win over BusyBox's applets, as they do over PATH.
   - `recipes/bat.json` builds bat 0.26.1 from its crate on crates.io, with
     its own release profile, and the files of its release zip: man page and
     shell completions from its build script.
   - SQLite and ripgrep pin the new zig, ripgrep and bat the new Rust.
3. **The end-to-end suites in CI, and sources next to images.**
   - `zigsaw push --sources` pushes the build's pinned sources and what its
     vendor steps made, from the download cache, to the image's repository,
     under a manifest tagged `sha256-<image digest>.sources`.
   - A pinned source whose URL fails, or serves other bytes, is fetched by
     its sha256 from next to the image of the recipe's app in the default
     registry. So is what a pinned vendor step makes, when its commands
     fail. `scripts/publish.sh` pushes the sources.
   - The suites that download take `SEED_DOWNLOADS`, as hard links where
     they can. `tests/zot.sh` starts the two registries `registry.sh` wants,
     one with a login whose password is new each run.
   - The Reproduce workflow runs, after `published.sh`, a step per suite,
     each whether or not earlier ones passed, with the build store as
     `SEED_DOWNLOADS` and as the matrix's store. Its timeout is 90 minutes.
   - After CI's first runs: the matrix gives apps an empty stdin, and marks
     the known AppContainer gaps.

### Code map

Changed since iteration 5:

| Area | Changes |
|---|---|
| Shims | `exports.zig`: command directories, the scan, one sync for installs and runs. `Sidecar.zig`: `eql`. `Store.zig`: `bin.lock` |
| Running | `run.zig`: the sync after a run |
| Building | `builder.zig`: `BB_OVERRIDE_APPLETS`, the vendor step's fallback |
| Sources | `fetch.zig`: the fallback to sources next to the image. `remote.zig`: `push --sources`, `fetchSource`. `Registry.zig`: blobs by digest alone. `oci.zig`: the sources manifest's types and tag |
| Recipes | `bat.json` (new); zig's aliases and variables; Rust's `CARGO_HOME`; pins |
| Tests | `zot.sh`, `htpasswd.zig` (new); `SEED_DOWNLOADS` in every suite that downloads; the matrix's `gap` and bat rows; new fixtures for C++, resources and the cc crate |
| CI | Every suite, after `published.sh` |

About 7,900 lines of Zig in `src/` (7,500 after iteration 5). Still no
dependencies beyond the Zig 0.16 standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 50 of 50 pass (47 after iteration 5) |
| [`tests/build.sh`](../tests/build.sh) | 59 of 59 pass (58 after iteration 5) |
| [`tests/shims.sh`](../tests/shims.sh) | 23 of 23 pass (17 after iteration 5) |
| [`tests/registry.sh`](../tests/registry.sh), with logins, through [`tests/zot.sh`](../tests/zot.sh) and zot's minimal build | 44 of 44 pass (39 after iteration 5) |
| [`tests/matrix.sh`](../tests/matrix.sh) | 0 mismatches, 11 known gaps, all under AppContainer, as before. bat's rows as intended in both sandboxes |
| [`tests/store.sh`](../tests/store.sh), [`ctrlc.sh`](../tests/ctrlc.sh), [`batch.sh`](../tests/batch.sh) | All pass |
| [`tests/published.sh`](../tests/published.sh), locally | 51 of 51 pass (46 after iteration 5). All ten published images, bat included, have the digests of fresh builds, and pull anonymously |
| Reproduce workflow on GitHub | Not checked from here (the repository is private, and `gh` isn't installed). The matrix's part of one run, shared from GitHub, led to the matrix's two fixes; the runs since haven't been seen |

New checks:

- `shims.sh`: `npm install -g` of a local package gives its command a
  shim, which runs with its arguments as typed and shows in `list`;
  `--ephemeral` runs give none; another app's name keeps its owner;
  `npm uninstall -g` removes the shim; a rebuild keeps it
- `build.sh`: `cargo install` of a local crate gives a working shim. The C
  fixture builds with the aliases only: C and C++ (without the C++
  runtime), `ar` and `ranlib`, and a string table through `rc`. The Rust
  fixture compiles C with the cc crate, prints from it, writes to `stderr`
  from it, and rebuilds to the same image
- `registry.sh`: `push --sources`; a build whose URL is gone, or serves
  other bytes, takes the file from next to the image and makes the same
  image; without sources there, the build says so; a pinned vendor step
  whose commands fail takes what they'd make from there
- `matrix.sh`: bat runs, highlights a file in its granted working
  directory, and can't read an ungranted one under AppContainer

Checked by hand:

- **bat three times:** in two stores at different paths, both cold, and
  again with zig's cache warm. One image, `sha256:d5cc8665…`.
- **ripgrep with the new zig and Rust:** the same layer as before, so the
  same `rg.exe`.
- **`tsc` by name** after the sync picked up the matrix store's earlier
  `npm install -g typescript`.

### Measurements

On the development machine:

| What | Time |
|---|---|
| The sync after a run, nothing to change / adding two shims | 2–3 ms / 93 ms |
| bat's vendor step | 252 s |
| bat, cold / with zig's cache warm | 217–221 s / 194 s |
| bat's layer | 6.9 MB, 11 files |
| The C fixture, cold (zig builds its resource compiler on first use) | 77–81 s (31 s before `rc`) |
| `shims.sh`, `store.sh`, `ctrlc.sh`, seeded | 33 s, 22 s, 30 s |
| `tests/published.sh`, ten images, with the builds cached | 238 s |

## Decisions made along the way

- **The aliases name the target.** `zig cc` without `-target` builds for
  the machine it runs on, CPU included. A caller's own `-target` still
  works: zig takes the last.
- **`ranlib` joined the aliases**, for makefiles and configure scripts that
  call it.
- **The cc crate's flags are fixed**: `-O3 -ffunction-sections
  -fdata-sections`, which it passes in a release build. Turning its defaults
  off is the only way to keep its `--target` from zig, and takes the
  profile's flags with it.
- **Sources go next to the image, in its own repository**, rather than in
  one shared `sources` repository. Each app's package is already public, a
  build knows its recipe's id, and nothing new has to be set up.
- **Their manifest is tagged by the image's digest**, so republishing a
  version with other sources doesn't overwrite the old ones.
- **The fallback is only a fallback.** A source's URL is tried first; the
  registry only when it fails or serves other bytes. A vendor step's commands
  run first, and a result that differs from the pin still fails the build.
- **Pushing sources is opt-in** (`--sources`): it can be large (zig's 97 MB
  zip, Rust's 150 MB of tarballs), and only publishers need it.
- **Hard links for `SEED_DOWNLOADS`**, since the matrix store's downloads
  are 2 GB. Cached downloads are never changed in place, so sharing them is
  safe.
- **CI's temporary directory is the runner's** `D:\a\_temp`: short paths for
  Rust, and on the build store's drive, so seeding links. A first step sets
  the paths, since a job's `env` can't use the `runner` context.

## Bugs found

In zigsaw, outside new code:

- **Aliases didn't win over BusyBox's applets.** BusyBox's sh runs its own
  `ar`, `make`, `patch` and others before anything on PATH, so an alias of
  one of those names was ignored in sh commands. It didn't show while the
  only alias was `dlltool`. Builds now list their aliases in
  `BB_OVERRIDE_APPLETS`.

In tests, caught before their slice was done:

- `build.sh` didn't copy the Rust fixture's new `build.rs` and `greet.c`.
- A `registry.sh` check counted fresh stores in a subshell, so its second
  build reused the first's store and had nothing to fetch.
- In CI, the matrix's ripgrep check searched an empty stdin (see Findings).

## Findings

- **The cc crate doesn't work with `zig cc` by itself on Windows.** For
  `x86_64-pc-windows-gnu` on a Windows host it looks for `gcc.exe`, and it
  passes `--target=x86_64-pc-windows-gnu` to any clang-like compiler, zig
  included, which zig 0.16 refuses ("unable to parse target query
  'x86_64-pc-windows-gnu': UnknownOperatingSystem"). Its zig detection (by
  "ziglang" in `--version`, which zig 0.16's doesn't print, or "zig" in the
  file name) doesn't change that in 1.6.0. `CRATE_CC_NO_DEFAULTS=1` turns
  the flag off, with all its other defaults.
- **C compiled against zig's UCRT headers links with Rust's msvcrt.** zig's
  MinGW headers are for UCRT (`__MSVCRT_VERSION__` 0xE00), Rust's MinGW
  libraries for `msvcrt.dll`. `snprintf`, `fprintf(stderr, …)`, `strtol`,
  `getenv`, oniguruma, libgit2 and zlib all linked and work, and the
  executables import only `msvcrt.dll`.
- **BusyBox-w32 runs its applets before PATH**, and `BB_OVERRIDE_APPLETS`
  (names separated by spaces, commas or semicolons) makes PATH win for the
  names listed. Of zig's aliases, only `ar` is also an applet.
- **zig links `.res` files**, and `zig rc` builds its resource compiler on
  first use, which takes about 50 s with a cold cache.
- **bat reproduces without extra flags**, its C included: C paths are on
  `B:`, and clang writes no timestamps.
- **frippery.org, the only download site of busybox-w32, answered 403 to
  everyone** from 2026-10-03, its home page included. busybox-w32 has no
  releases on GitHub. The pinned file from the download caches made the
  sources next to BusyBox's image, and builds of its recipe work again.
- **ripgrep searches stdin when it's a pipe** and no path is given, as in
  a GitHub Actions step. The matrix runs apps with an empty stdin.
- **On Windows Server 2025, an AppContainer can't open `NUL`**: git fails at
  startup ("could not open '/dev/null' for reading and writing"), even for
  `--version`. On Windows 11 it can. Seen on GitHub's `windows-2025` runner.
- **A job's `env` can't use the `runner` context** in GitHub Actions; a
  step can, and `$GITHUB_ENV` passes values to the steps after it.

## Upstream issues

Worth reporting, if not known:

1. **zig cc refuses LLVM target triples with a vendor**
   (`x86_64-pc-windows-gnu`), which build tools such as the cc crate pass.
2. **The cc crate passes `--target` to zig cc** even when it has recognized
   it, and on a Windows host it doesn't find a `cc`.

## Known gaps

- **Builds.**
  - Vendor steps run their commands with network access and nothing more
    confining than a build's sandbox; only what they leave in `dir` is
    pinned.
  - Network access is still discouraged by proxy variables, not blocked.
  - Builds need `B:` free, and run one at a time.
  - MSVC images don't reproduce on other machines, and only x64 MSVC builds
    are set up.
- **Rust.**
  - Rust builds need zig in their SDK, for `dlltool` and C.
  - Only `x86_64-pc-windows-gnu` is set up.
  - Crates' C is compiled with fixed flags, against UCRT headers, and
    linked with msvcrt: C that needs what only UCRT has would fail to link.
  - The store's path must be shorter than about 100 characters.
- **Sources next to images.**
  - Only for images pushed with `--sources`, and only from the default
    registry, next to the image of the recipe's own app id.
  - Local `path` sources aren't pushed.
- **Commands from runs.** A command that names the app's files by absolute
  path, as pip's launchers do, breaks when an update deploys the app
  elsewhere. Python's embeddable image has no pip to try it with.
- **Registries.** Each layer goes up in one request, an app's runtime layers
  go to the app's repository, and layers aren't compressed. Sources now add
  to what a publish uploads.
- **AppContainer.** Git, Node scripts, npm, Python's realpath and zig still
  fail under it (now marked as known gaps in the matrix), and on Windows
  Server 2025 git doesn't start at all.
- The gaps from earlier iterations remain: the registry isn't isolated,
  logins don't come from Docker's configuration, and runtimes can't have
  runtimes.

Not yet tested:

- **A green Reproduce run** with this iteration's suites. The first run's
  matrix showed the ripgrep and AppContainer differences that are now
  handled; whether the rest passes on a hosted runner (Credential Manager
  for the login checks, the pseudoconsole for `ctrlc.sh`, `subst` and MSVC
  for `build.sh`) hasn't been seen from here.

## Suggested for iteration 7

1. **Look at the Reproduce run** and fix what fails only on a hosted
   runner.
2. **CMake and Ninja**, now that builds have `cc`, `c++`, `ar` and `rc`.
   CMake's rules for Clang on Windows may pass zig flags it doesn't expect.
3. **Go**, with `go mod vendor` as a vendor step.
4. **A faster CI job**: the job builds zig, Rust, ripgrep and bat from
   scratch on every run. Caching the build store between runs, keyed by
   the recipes, would save most of that.
5. **Cheaper pushes and pulls**: chunked uploads, cross-repository mounts
   for runtimes' layers, perhaps compression. Sources make publishing
   upload more.
6. **Shorter deployment paths**, to keep tools like rustc under Windows'
   path limit in deeper stores.
