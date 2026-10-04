# Iteration 8: C for CMake and cgo, and AppContainers re-checked

Concluded 2026-10-05.

## Outcome

Iteration 7 left builds with zig's C compiler under the names build tools
look for (`cc`, `c++`, `ar`, `rc`), but only hand-written commands and the
cc crate used them. Most C and C++ projects build with CMake, which builds
had no image for, and Go builds had no cgo. Under AppContainer, several
known gaps had started to pass on the development machine, and nobody knew
why. Zigsaw now:

- **builds CMake projects**: a CMake image with Ninja, and zig's image
  telling CMake its compilers and how to link reproducibly. zstd is built
  from source with it;
- **builds Go programs with C** (cgo), through zig's `cc`, reproducibly;
- **knows what each Windows lets AppContainers do**: a probe checks the
  known causes from inside one, and the matrix expects what it finds. On
  Windows 11 26300.9550, git and Node now work under AppContainer for most
  of what the matrix checks;
- **turns links in source archives into copies** of the files they point
  to, as zstd's archive needs.

All fifteen published images, CMake and zstd included, have the digests of
fresh builds of their recipes, and their sources next to them on ghcr.io.
The Reproduce workflow is green, in 31 of its now 60 minutes.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| The Reproduce run's time (iteration 7's first suggestion) | Already answered when planning: the last green run took 30 of its 120 minutes. No download cache in CI; the timeout drops to 60 minutes |
| Scope | C builds (CMake + Ninja, cgo, both through zig's `cc`) and an AppContainer re-check, with a low-integrity probe. Shorter deployment paths and GUI apps wait |
| CMake and Ninja | One SDK image, `org.cmake.cmake` 4.4.4, with Ninja 1.13.2 inside and `CMAKE_GENERATOR=Ninja` |
| CMake's proof app | zstd 1.5.7 (`com.github.facebook.zstd`), published; C++ through CMake in a `build.sh` fixture |
| cgo's proof | A `build.sh` fixture only |
| Low integrity | Probed only, for the findings; no sandbox code |
| Where `CC` and `CXX` go | zig's image env, as iteration 6 put the cc crate's variables there |
| The matrix's AppContainer expectations | Set by what a probe finds on the Windows it runs on, not by build number |

Decided during the iteration:

| Decision | Choice |
|---|---|
| Reproducible cgo (slice 1) | `CGO_LDFLAGS=-s -Wl,-Brepro` in zig's image env, and `-ldflags=-buildid=` in each recipe that uses cgo. Chosen over `-buildid=` in Go's `GOFLAGS`, which a recipe's own `-ldflags` would replace anyway, and over everything per recipe |
| CMake's resource compiler and link flags (slice 2) | `RC=rc` and `LDFLAGS=-s -Wl,-Brepro` in zig's image env too, following the choice for cgo |
| Links in source archives (slice 2) | A link to a file in the same tar becomes a copy of it; links to directories, or out of the archive, fail |
| What CMake's image leaves out (slice 2) | The GUI and its Qt help, the HTML documentation and the man pages; `cmake --help-*` still works |
| git under AppContainer (slice 3) | `GIT_DISCOVERY_ACROSS_FILESYSTEM=1` in MinGit's image env. Chosen over an override in the README, and over leaving the gap |
| Node under AppContainer (slice 3) | `NODE_OPTIONS=--preserve-symlinks --preserve-symlinks-main` in Node's image env. Chosen over an override in the README, the recommendation, and over leaving the gap |

The decisions of iterations 1–7 still hold.

## What was built

The iteration ran as three slices, each ending in working, tested code.

1. **cgo through zig's cc.**
   - A probe first, in two short stores: a Go program calling C, with Go,
     zig and BusyBox in its SDK. With `CC=cc`, cgo was on and the program
     ran, but every build made another image (see Findings).
   - zig's image sets `CC=cc`, `CXX=c++` and `CGO_LDFLAGS=-s -Wl,-Brepro`.
     SQLite, ripgrep and bat pin the new image.
   - `tests/build/cgo/`: a Go program calling C in its preamble and in a C
     file, which calls Windows. Its recipe builds with
     `-ldflags=-buildid=`.
2. **CMake + Ninja, and zstd.**
   - A probe first: CMake's zip as an image (what cleanup can drop), the C
     fixture's sources as a CMake project, zstd, two stores, and both under
     AppContainer.
   - `recipes/cmake.json`: Kitware's Windows zip and Ninja's, exporting
     `cmake`, `ctest`, `cpack` and `ninja`.
   - zig's image also sets `RC=rc` and `LDFLAGS=-s -Wl,-Brepro`, which
     CMake reads (see Findings).
   - `recipes/zstd.json`: zstd 1.5.7 from its release tarball, configured,
     built and installed with CMake, multithreaded. It exports `unzstd`
     and `zstdcat` too, as zstd's install on Unix links them.
   - Tar sources: zstd's tarball has two links among its tests, which
     zigsaw refused. A link to a file in the archive now becomes a copy of
     it: an entry pointing at the target's bytes in the tar.
   - `tests/build/cmake/`: the C fixture's sources, as a static library of
     C and C++ and a program with resources that links it as C++.
3. **The AppContainer re-check.**
   - `tests/acprobe.zig` (`zig build acprobe`): checks the known causes from
     wherever it runs, and with `--low <command>` runs a command at low
     integrity.
   - Each remaining failure's cause, by its error message, git's and Node's
     sources, and experiments. git and Node get variables that avoid two of
     them (see Findings).
   - The matrix runs the probe under AppContainer first and prints what it
     found. Each known gap names the probe checks its causes need, and is
     expected to pass where they all pass.
   - `docs/findings.md`: what changed, what each failure needs, and how
     the tools fared at low integrity.

### Code map

Changed since iteration 7:

| Area | Changes |
|---|---|
| Sources | `Tree.zig`: links in tar sources become copies of their files (`listTar`, `resolveLink`, `linkTargetPath`) |
| Build | `build.zig`: the `acprobe` step |
| Recipes | `cmake.json`, `zstd.json` (new). `zig.json`: `CC`, `CXX`, `RC`, `LDFLAGS`, `CGO_LDFLAGS`. `mingit.json`: `GIT_DISCOVERY_ACROSS_FILESYSTEM`. `node.json`: `NODE_OPTIONS`. Pins in SQLite, ripgrep, bat and Prettier |
| Tests | `acprobe.zig` (new). `build.sh`: CMake and cgo, with new fixtures `tests/build/cmake` and `tests/build/cgo`. `matrix.sh`: the probe and `ac_if`, CMake's and zstd's rows. `published-recipes.txt`: CMake, zstd |
| CI | Timeout 60 minutes |
| Docs | `findings.md`: the re-check and low integrity |

About 8,350 lines of Zig in `src/` (8,240 after iteration 7). Still no
dependencies beyond the Zig 0.16 standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 56 of 56 pass (54 after iteration 7) |
| [`tests/build.sh`](../tests/build.sh) | 72 of 72 pass (65 after iteration 7) |
| [`tests/registry.sh`](../tests/registry.sh), through [`tests/zot.sh`](../tests/zot.sh) | 48 of 48 pass |
| [`tests/matrix.sh`](../tests/matrix.sh) | 0 mismatches, 3 known gaps failed (8 after iteration 7): `git init`/commit, `npm install -g` and Node's `fs.realpathSync`, all for the drive root. CMake's and zstd's rows as intended in both sandboxes |
| [`tests/store.sh`](../tests/store.sh), [`shims.sh`](../tests/shims.sh), [`ctrlc.sh`](../tests/ctrlc.sh), [`batch.sh`](../tests/batch.sh) | All pass, after Node's and MinGit's new variables |
| Published images | All fifteen on ghcr.io have the digests of the builds here, and their sources tags (checked by asking ghcr.io for each manifest anonymously) |
| Reproduce workflow on GitHub | Green on "iter 8 wip" (424f7f3), after the republish: 31 minutes |

New checks:

- `build.sh`: CMake's image builds; a CMake project of C, C++ and resources
  builds with zig, runs as `cmake --install` installed it, and rebuilds to
  the same image. A Go program with C builds with cgo on by itself, runs,
  and rebuilds to the same image.
- `matrix.sh`: CMake runs and hashes a file; zstd runs, compresses and
  restores a file, and can't read an ungranted one under AppContainer. Ten
  known AppContainer gaps are now expected to pass where the probe finds
  their causes lifted, as on the development machine.
- Unit tests: links in a tar source, through a link to a link, come out as
  copies; links to a directory, to nothing, out of the archive and to an
  absolute path fail. Link targets resolve against the link's directory.

Checked by hand:

- **The cgo fixture in two stores**, one at a longer path, cold and warm:
  one image.
- **The CMake fixture in two stores**, and rebuilt: one image.
- **zstd in three stores**: one image. `-T0 -19` and back through `unzstd`,
  `zstdcat`, and its benchmark.
- **CMake and zstd under AppContainer**, from a granted directory.
- **The probe** in both sandboxes and at low integrity, and the tools at
  low integrity (see Findings).
- **A CMake project with a compile error**: Ninja reports it and stops.

### Measurements

On the development machine:

| What | Time |
|---|---|
| Installing CMake's image, before / after cleanup | 16 s / 8.7 s |
| The cgo fixture, cold / warm | 58–78 s / 15 s |
| The CMake fixture, cold / warm | 92–122 s / 4 s (cold, zig builds libc++ first) |
| zstd, cold / warm | 189 s / 24 s |
| `build.sh`, seeded | 573 s (420 after iteration 7) |
| The matrix, warm | 60 s |
| `registry.sh` through `zot.sh` | 37 s |

On GitHub's runner, the Reproduce job took 31 minutes (29.5 after
iteration 7): `published.sh` 16.4, `build.sh` 10.7, the matrix 0.7.

The new images:

| Image | Files | Size | gzip |
|---|---|---|---|
| CMake, as released | 8,818 | 156 MB | 47 MB |
| CMake, as published | 4,158 | 61 MB | 21 MB |
| zstd | 4 | 1.1 MB | 0.46 MB |

## Decisions made along the way

- **What makes builds with zig reproducible lives in zig's image**: the
  compilers' names for CMake, make and Go (`CC`, `CXX`, `RC`), and how to
  link (`LDFLAGS`, `CGO_LDFLAGS`). Recipes don't repeat them.
- **`-buildid=` is per recipe**, not in Go's `GOFLAGS`: recipes nearly
  always pass `-ldflags` of their own, for `-X` versions, and that would
  replace a default anyway.
- **Ninja comes inside CMake's image**: `CMAKE_GENERATOR=Ninja` is then
  always right, and recipes list one image fewer.
- **Links in tars become copies, without extra data**: the copy's entry
  points at the target's bytes in the archive. Links to directories fail,
  as no source has needed them.
- **The probe stays in the repository**, and the matrix runs it, so CI's
  log shows what Windows Server 2025 allows. A gap's expected outcome
  names every check its cause might need: an extra check only shows a pass
  as a known gap, and a missing one would fail CI where it can't be
  checked from here.
- **`published.sh` wasn't run before the republish**: it would have
  downloaded 465 MB to report the seven changed images as different.

## Bugs found

In tests, caught before their slice was done:

- The matrix's zstd row wrote compressed bytes to bash, which warned about
  a null byte.

Upstream:

- **zig 0.16's `cc -###` always exits 1** (see Findings). zig 0.17.0's
  source handles `-###` the same way.
- **Ninja 1.13.2 crashes** (exit code `0xC0000409`) when a command it runs
  can't be started, instead of reporting it. A command that fails is
  reported as usual.

## Findings

- **Go can't identify zig's C compiler.** Go asks the C compiler for its
  version with `cc -### -x c -c -` and hashes the answer into the build ID.
  zig prints the version, then fails, looking for an object file that
  `-###` never makes; Go hashes the error instead, which names a random
  temporary file and the store's path. Every cgo build gets another build
  ID, so another image.
- **zig asks lld for reproducible output only when optimizing**
  (`-BREPRO`, unless `-Wl,-Brepro` asks for it), and writes a PDB unless
  told `-s`. Go links cgo programs with the C compiler, without `-O`, and
  the PDB names Go's temporary directories. Even stripped, an unoptimized
  link carries the time.
- **CMake sees zig's `cc` as Clang for MinGW**, and finds its compilers and
  the archiver through `CC`, `CXX` and the aliases. For resources it looks
  for GNU's `windres`, unless `RC` names another compiler; then it uses
  `rc.exe`'s options, which zig's `rc` takes.
- **Restriction 1 is gone on Windows 11 26300.9550.** AppContainers can
  open the Mount Manager and get paths with drive letters. It changed with
  the updates installed on 2026-10-03.
- **Restriction 2 is wider than the drive root.** An AppContainer can't
  read the attributes of any directory that grants it nothing: the drive
  root, `C:\Users`, the parents of granted paths.
  - git stats the working directory's parent while looking for a
    repository; `GIT_DISCOVERY_ACROSS_FILESYSTEM=1` skips that. Creating
    files, it stats each directory of their path, so `init` and `commit`
    still fail.
  - Node's JavaScript realpath, which it uses for scripts and modules,
    `lstat()`s each directory of a path; the preserve-symlinks options skip
    it. npm itself `lstat()`s `C:\Users` for `install -g`.
- **Low integrity suits every tool tested.** With their home and working
  directory labelled low, git, Node with npm, Python and zig work, and
  writing anywhere else is denied. Reading and the network stay open.
- **Granting an AppContainer access to a file hides it from low
  integrity.** A file whose ACL allows a particular AppContainer can't be
  read by a low-integrity process outside it, though the user has full
  access. zigsaw grants each app's AppContainer its deployments on its
  first `--sandbox=appcontainer` run, so after that zig can't find itself
  at low integrity, and Python doesn't start.
- **CI's time stays well within an hour**: 31 minutes, with CMake, zstd and
  the new checks.

## Known gaps

- **cgo** works only in builds that list zig. Until zig's `cc -###`
  succeeds, recipes that use it leave out Go's build ID, and executables
  linked with zig's variables have no debug information.
- **CMake and Go run as apps** have no C compiler: aliases are only for
  builds, and runtimes can't have runtimes.
- **Node's image** resolves symlinked packages (`npm link`, workspaces,
  pnpm) from where the link is, in both sandboxes.
- **AppContainer.**
  - On Windows 11 26300.9550, `git init`/`commit`, `npm install -g` and
    Node's `fs.realpathSync` fail.
  - Earlier builds of Windows 11 don't let AppContainers resolve real
    paths.
  - Windows Server 2025 denies them `NUL`.
- **Links in source tars** to directories, or out of the archive, fail the
  build.
- The gaps from earlier iterations remain: each blob up in one request;
  mounts only from where an app was pulled or a runtime's sibling
  repository; digests tied to the Zig zigsaw is built with; Go vendor steps
  that download every module; vendor steps' network access; builds one at
  a time on `B:`; MSVC images; Rust's need for zig and its store path
  limit; sources only from the default registry; pip-style launchers after
  updates; the registry not isolated; logins not from Docker's
  configuration; runtimes without runtimes.

Not yet tested:

- **What Windows Server 2025 allows AppContainers.** The matrix prints the
  probe's results in the Reproduce log, which wasn't seen from here.
- **A build that couldn't keep zig's cache**: once, on a failed build,
  moving zig's cache back into the store was denied, and the next build
  started cold. It didn't happen again; Defender scanning the files zig had
  just written is the likely cause.

## Suggested for iteration 9

1. **A low-integrity sandbox**: runs labelled low, with their data and
   granted paths labelled low too, and deployments granted to AppContainers
   in a way that doesn't hide them from low integrity (such as through
   `ALL APPLICATION PACKAGES`). Unlike AppContainer, it suits every tool
   tested, but confines writing only.
2. **Read the probe's results from CI**, and record what Windows Server
   2025 allows.
3. **Shorter deployment paths**, carried over again.
4. **Report zig's `cc -###` and Ninja's crash upstream**, and drop
   `-buildid=` from cgo recipes once zig answers.
5. **Retry moving a tool's cache back** when Windows refuses for a moment.
