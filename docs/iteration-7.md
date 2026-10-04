# Iteration 7: smaller images, and Go

Concluded 2026-10-05.

## Outcome

Iteration 6 left images as plain tar layers: every pull downloaded zig's
378 MB and Rust's 649 MB in full, and every publish uploaded them again,
runtimes' layers included, though the registry had them already. Builds had
zig, Rust and MSVC, but not Go, the other big source of command-line tools.
And the end-to-end tests' registry came from outside: an unpinned
`bin\zot.exe` on the development machine, a release download in CI.
Zigsaw now:

- **compresses layers with gzip**: the thirteen published images hold 1.6 GB
  of files, and a pull of all of them downloads 465 MB. zig's layer is
  88 MB, Rust's 179 MB;
- **mounts blobs a registry already has**: pushing an app mounts its
  runtimes' layers from their own repositories, and all of an app pulled from
  another repository on the same registry;
- **builds Go**: a Go SDK image whose defaults make builds hermetic and
  reproducible, with fzf and zot built from source;
- **runs its tests' registry itself**: `tests/zot.sh` runs the zot that
  zigsaw builds, with zigsaw, on the development machine and in CI.

All thirteen published images, Go, fzf and zot included, have the digests of
fresh builds of their recipes, and their sources next to them on ghcr.io.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Scope | Smaller images (gzip layers, cross-repository mounts) and Go (an SDK image, with fzf and zot from source). CMake + Ninja, a faster CI job and shorter deployment paths wait |
| Chunked uploads | Not this time: with gzip, the biggest blob is 179 MB, and ghcr.io took 649 MB in one request |
| Go's image id | `org.golang.go` |
| Go's build flags | In Go's image `env`, as zig's image carries the cc crate's settings: `GOFLAGS=-trimpath -modcacherw`, `GOTOOLCHAIN=local` |
| Go apps | fzf, and zot's minimal build (`dev.zotregistry.zot`), the version CI already used |
| The tests' zot | Run by zigsaw, if the zot zigsaw builds passes `registry.sh` |

Decided during the iteration:

| Decision | Choice |
|---|---|
| zigsaw's build mode (slice 1's probe) | ReleaseSafe by default: in Debug, compressing zig's layer took 74 s instead of 9 |
| The compression level (slice 1's probe) | zlib's default, 6: level 9 made zig's layer 1% smaller in 2.4 times the time |
| zot's dependencies (slice 3) | Its vendor step keeps only the packages its minimal build needs: 68 MB instead of `go mod vendor`'s 415 MB. Chosen over the full vendor tree, a pinned module cache (1.55 GB), and upstream's prebuilt binary |
| Go builds under AppContainer on Windows Server 2025 (after the republish) | A known gap in the matrix, like git's there: both are denied `NUL` |

The decisions of iterations 1–6 still hold.

## What was built

The iteration ran as four slices, each ending in working, tested code.

1. **gzip layers.**
   - A probe first, on zig's and Rust's layers: gzip with Zig 0.16's
     deflate, at two levels, in Debug and ReleaseSafe; its bytes the same
     every time and in both modes; GNU `gzip` and `tar` read them.
   - Images' layers are `application/vnd.oci.image.layer.v1.tar+gzip`:
     the deterministic tar, compressed and hashed as it's written. Plain tar
     layers still pull, run and push. What vendor steps make stays a plain
     tar, as recipes pin its hash.
   - Deploying a gzip layer decompresses it to a temporary tar first, which
     the parallel extraction reads.
   - `zig build` makes a ReleaseSafe `zigsaw.exe` unless told otherwise.
   - Every image's digest changed, so every pin did.
2. **Cross-repository mounts.**
   - A blob the target repository lacks is mounted from where it already
     is: a runtime's layer from the runtime's repository next to the app's;
     all of an app pulled from another repository on the same registry from
     that one. A registry that answers with an upload instead gets the blob
     uploaded, in the upload it started.
   - Tokens also ask to pull from those repositories, and are asked for
     again without them if refused.
3. **Go, fzf and zot.**
   - A probe first, in short stores: Go's image; a module with no
     dependencies, in two stores; fzf with a vendor step; `go install`; zot,
     whose `go mod vendor` turned out to be 415 MB (see Findings).
   - `recipes/go.json`: Go 1.27.1's Windows release without its test suite,
     with `GOPATH=${data}\go` (its `bin` on PATH), `GOCACHE=${cache}`,
     `GOTOOLCHAIN=local` and `GOFLAGS=-trimpath -modcacherw`.
   - `recipes/fzf.json` and `recipes/zot.json` build fzf 0.74.4 and zot
     2.1.21's minimal binary from their module zips on proxy.golang.org,
     with their upstream release flags. zot's vendor step prunes what
     `go mod vendor` made to the packages `go list -deps ./cmd/zot` names.
   - Under AppContainer, runs get the temporary directory Windows gives the
     container (see Bugs found).
4. **The tests' zot, run by zigsaw.**
   - `tests/zot.sh` runs `dev.zotregistry.zot` from `ZOT_HOME` or
     `BUILD_HOME`, or builds BusyBox, Go and zot from their recipes in a
     temporary store. Ending zigsaw ends zot, through the run's job object.
   - CI's registry step uses the zot `published.sh` built, and downloads
     nothing.

### Code map

Changed since iteration 6:

| Area | Changes |
|---|---|
| Layers | `layer.zig`: gzip, gunzip, inflate. `Tree.zig`: `writeLayerFile` compresses. `oci.zig`: the gzip layer type. `Store.zig`: `deploy` inflates. `builder.zig`: gzip image layers |
| Registries | `Registry.zig`: `startUpload` (with a mount) and `finishUpload`, `pull_from` and the token's scopes. `remote.zig`: where to mount each blob from |
| Running | `run.zig`: the AppContainer's temporary directory |
| Build | `build.zig`: ReleaseSafe for `zigsaw.exe` |
| Recipes | `go.json`, `fzf.json`, `zot.json` (new); pins |
| Tests | `zot.sh` runs zot with zigsaw; `build.sh`: gzip layers, Go (new fixture `tests/build/go`); `registry.sh`: a plain-tar image, mounts; the matrix's go, fzf and zot rows; `published.sh`: Go's smoke run |
| CI | zot from the build store; timeout 120 minutes |

About 8,200 lines of Zig in `src/` (7,900 after iteration 6). Still no
dependencies beyond the Zig 0.16 standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 54 of 54 pass (50 after iteration 6) |
| [`tests/build.sh`](../tests/build.sh) | 65 of 65 pass (59 after iteration 6) |
| [`tests/registry.sh`](../tests/registry.sh), through [`tests/zot.sh`](../tests/zot.sh) and the zot zigsaw builds | 48 of 48 pass (44 after iteration 6), as against upstream's full zot before the switch |
| [`tests/matrix.sh`](../tests/matrix.sh) | 0 mismatches, 8 known gaps failed (git and Node under AppContainer). go, fzf and zot's rows as intended in both sandboxes |
| [`tests/store.sh`](../tests/store.sh), [`shims.sh`](../tests/shims.sh), [`ctrlc.sh`](../tests/ctrlc.sh), [`batch.sh`](../tests/batch.sh) | All pass, after slice 1's change to deploying |
| Published images | All thirteen on ghcr.io have the digests of the builds here, and their sources tags (checked by asking ghcr.io for each manifest anonymously) |
| Reproduce workflow on GitHub | Green before this iteration. After the republish, the user shared two failures, both since fixed: Go's run in `published.sh` (`go --version`), and Go's build under AppContainer on Windows Server 2025 |

New checks:

- `build.sh`: an app's layer is `tar+gzip`, and `tar` lists it. Go's image
  builds; `go install` gives a shim; a Go program builds, runs with its
  paths trimmed, calls Windows, and rebuilds to the same image
- `registry.sh`: an image with a plain tar layer, made by the test, pulls,
  runs and pushes. Pushed by app id, an app mounts its runtime's layer from
  the runtime's repository; a pulled app pushed to another repository is
  mounted whole; also on the registry that wants a login
- `matrix.sh`: go runs, and builds and runs a module in its working
  directory; fzf runs and filters stdin; zot runs and verifies a config

Checked by hand:

- **Compression**: zig's and Rust's layers, at levels 6 and 9, in Debug and
  ReleaseSafe: the same bytes from both modes and every run, decompressing
  to the original tar, read by GNU `gzip` and `tar`.
- **Go in two stores** at different paths, cold and warm: one image for the
  fixture, and one for fzf, its vendor step run in each.
- **zot's vendor step run again** in another store: the pinned hash, and the
  same image.
- **`registry.sh` against the zot zigsaw built**, run from its deployment,
  before `zot.sh` was changed to run it: 48 of 48.
- **`zot.sh` without a store holding zot**: it builds BusyBox, Go and zot,
  the checks pass, and the store is removed.

### Measurements

On the development machine:

| What | Time |
|---|---|
| Compressing zig's layer (378 MB), ReleaseSafe / Debug | 9.4 s / 74 s |
| Compressing Rust's layer (649 MB), ReleaseSafe | 18 s |
| Decompressing zig's layer, ReleaseSafe / Debug | 1.5 s / 16.7 s |
| Compiling zigsaw, ReleaseSafe | about 60 s |
| Deploying Go (13,800 files) | 27 s |
| The Go fixture, cold / warm | 6–7 s / 1–2 s |
| fzf, vendoring included / warm | 22 s / 3 s |
| zot's vendor step | 874–1006 s, and about 5 GB of temporary space |
| zot from its cached vendored packages | 65 s |
| `registry.sh` through `zot.sh`, zot installed / built first | 35 s / 207 s |
| `build.sh`, seeded | 420 s |
| The matrix, warm | 44 s |

The images' own layers, decompressed and as published:

| Image | Files | gzip |
|---|---|---|
| BusyBox | 0.7 MB | 0.4 MB |
| MinGit | 96 MB | 41 MB |
| Node.js | 109 MB | 38 MB |
| Prettier | 10 MB | 2.8 MB |
| Python | 25 MB | 12 MB |
| zig | 378 MB | 88 MB |
| SQLite | 1.6 MB | 0.8 MB |
| Rust | 649 MB | 179 MB |
| ripgrep | 3.9 MB | 1.6 MB |
| bat | 6.9 MB | 3.7 MB |
| Go | 249 MB | 71 MB |
| fzf | 6.4 MB | 2.5 MB |
| zot | 77 MB | 23 MB |
| All | 1.6 GB | 465 MB |

## Decisions made along the way

- **Every new layer is gzip**, without an option: one format, and the one
  every OCI tool reads. zstd would compress better, but Zig 0.16 can only
  decompress it.
- **No new config type.** zigsaw versions without gzip support refuse gzip
  layers with a clear message already.
- **Deploying decompresses to a temporary tar** rather than extracting as
  it decompresses: the parallel extraction, which matters more on Windows,
  needs to seek in a plain tar. zig's layer decompresses in 1.6 s; Defender
  takes 25 s over its files.
- **One place to mount each blob from**: the repository the app was pulled
  from, or else a runtime's repository in the default layout. A mount that
  fails costs nothing: the registry starts an ordinary upload instead.
- **Go's module zips from proxy.golang.org**, as sources: they never change
  once published, unlike archives GitHub makes on request.
- **Go's test suite left out of its image**: 3,500 files only Go's own
  tests read, a fifth of what Defender scans on install.
- **zot runs without `--ephemeral`** in the tests: ending zigsaw skips an
  ephemeral run's cleanup, which would leave a directory in the store each
  time, and zot keeps nothing in its data directory anyway.
- **The fallback in `zot.sh` builds zot's SDK from recipes too**, as the
  published images may not have the digests the recipes pin yet.
- **CI's timeout is 120 minutes**, for zot's vendor step.

## Bugs found

In zigsaw, outside new code:

- **Under AppContainer, Windows' temporary directory didn't exist.** In an
  AppContainer, `GetTempPath2` ignores `TEMP` and returns the container's
  own folder under `LOCALAPPDATA`, which zigsaw points into the data
  directory. Go asks for it this way (so does Rust's standard library), and
  `go run` failed. Runs now create it.

In tests, caught before their slice was done:

- `registry.sh`'s plain-image check: with `MSYS_NO_PATHCONV`, curl got
  `/dev/null` and `/c/...` paths unconverted; and `sha256sum` starts its
  line with a backslash for a file name with backslashes.
- `zot.sh` started zigsaw through a shell function, so ending it ended the
  subshell, and both zots kept running.

After the republish:

- `published.sh` ran `go --version`; Go takes `go version`.
- The matrix's Go build row failed under AppContainer on Windows Server 2025
  (see Findings); now a known gap.

## Findings

- **Zig 0.16's deflate is usable for layers**: deterministic, standard (GNU
  `gzip` and `tar` read it), about 40 MB/s at level 6 in ReleaseSafe. In
  Debug it is 8 times slower, and decompression 11 times.
- **`go mod vendor` vendors what any build of the module could need**: all
  build tags, so for zot all 561 modules (415 MB, 25,109 files), and it
  downloads and unpacks every one of them first. zot's minimal build needs
  1,016 packages from 166 modules: 68 MB, 5,115 files.
- **A module cache is no smaller**: it holds whole modules, so the 166
  modules unpack to 1.55 GB. Its `@v/list` files would also change as
  modules publish new versions.
- **`-trimpath` hides both the SDK's deployment and `B:`**: Go builds are
  the same in any store without anything more.
- **On Windows Server 2025, Go builds fail under AppContainer**: Go's
  toolchain opens `NUL` ("error obtaining buildID for go tool compile: open
  NUL: Access is denied"), which Server 2025 denies AppContainers, as found
  with git in iteration 6. On Windows 11 they work.
- **zot mounts across repositories** as the distribution specification
  says, with and without a login.
- **Several known AppContainer gaps pass on this machine now**: `git
  --version`, `zig env`, zig's project, and Python's realpath. On Windows 11
  10.0.26300 the matrix shows them as "ok (a known gap)". Why was not looked
  into; the matrix still expects them to fail, as CI's Windows Server 2025
  may.

## Known gaps

- **Images.**
  - A layer's compressed bytes, and so every digest, are what the deflate of
    the Zig zigsaw is built with makes. CI pins Zig 0.16.0.
  - Each blob goes up in one request.
  - Blobs are mounted only from the repository an app was pulled from, or a
    runtime's in the default layout.
- **Go.**
  - No cgo.
  - Vendor steps download every module `go.mod` names: zot's takes up to
    17 minutes and 5 GB of temporary space, for 68 MB.
- **AppContainer.** Git, Node scripts and npm still fail under it, and on
  Windows Server 2025 git doesn't start and Go builds fail.
- The gaps from earlier iterations remain: vendor steps' network access,
  builds one at a time on `B:`, MSVC images, Rust's need for zig and its
  store path limit, sources only from the default registry, pip-style
  launchers after updates, the registry not isolated, logins not from
  Docker's configuration, runtimes without runtimes.

Not yet tested:

- **A Reproduce run with the two fixes**, and how long the job takes now
  that it builds zot, against its 120 minutes.
- **Mounts on ghcr.io**: whether the republish mounted Node's layer for
  Prettier, and how ghcr.io answers a token request with extra scopes,
  wasn't seen from here.

## Suggested for iteration 8

1. **Look at the Reproduce run**: its time, and zot's vendor step's share
   of it. If it's long, keep the download cache between runs (keyed by the
   recipes' pins), which would also skip zig's and Rust's downloads.
2. **CMake and Ninja**, carried over from iteration 7's list.
3. **Shorter deployment paths**, carried over too.
4. **The AppContainer gaps that pass on Windows 11 now**: find out why,
   and update the findings and the matrix.
5. **cgo**, with zig's `cc`, for Go programs that need C.
