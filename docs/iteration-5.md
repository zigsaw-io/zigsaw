# Iteration 5: faster, wider builds

Concluded 2026-10-03.

## Outcome

Iteration 4 gave zigsaw real builds, but two things kept building from
source from being practical. Every build paid about 30 s for zig to build
its C runtime again, and only C built offline: modern command-line tools are
mostly Rust, and their dependencies come from a package registry, which
build steps can't reach. Zigsaw now:

- **keeps tool caches between builds**: an SDK image points a tool's cache at
  a new `${cache}` placeholder, and builds keep that directory. Building
  SQLite again takes 2 s instead of 42, and makes the same image;
- **fetches dependencies in a pinned vendor step**: a module's vendor
  commands run with network access before anything builds, and the recipe
  pins what they fetched by hash, as it pins downloads. The build itself
  stays offline, and the image hermetic;
- **builds Rust**, with a Rust SDK image of the official toolchain, which
  needs no Visual Studio. ripgrep is now built from its source on crates.io
  instead of repackaged from its release zip, and reproduces;
- **lets images give builds commands** ("aliases"), which is how Rust builds
  get the `dlltool` they need from zig.

All nine published images, the Rust image and ripgrep built from source
included, have the digests of fresh builds of their recipes.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Scope | Faster, wider builds: a tool cache and a new toolchain. Left for later: shims for commands installed at run time, cheaper pushes and pulls, the end-to-end suites in CI |
| Toolchain | Rust: the official `x86_64-pc-windows-gnu` component tarballs as an SDK image, and ripgrep built from source. Go and CMake wait |
| Dependencies | A pinned vendor step, as Nix's `vendorHash`: commands with network access, whose result is pinned by hash. It works for any tool, and is cached by hash, so rebuilds are offline |
| Tool cache | Declared by the SDK image, with a new `${cache}` placeholder |

Decided during slice 2, when the plan's assumption that Rust needs nothing
but its own toolchain turned out wrong (see Findings):

| Decision | Choice |
|---|---|
| `dlltool` for Rust | Build-time command aliases: an image declares commands it gives builds, and zig's gives `dlltool`. Chosen over wiring zig's `dlltool` into each Rust recipe, and over adding GNU's assembler from MSYS2 to the Rust image |

The decisions of iterations 1–4 still hold.

## What was built

The iteration ran as three slices, each ending in working, tested code.

1. **`${cache}` and zig's tool cache.**
   - A probe first: zig's cache on `B:\cache`, cold, warm, and moved
     between build roots of different lengths. The executables were
     identical, and the warm build took 0.4 s instead of 30.
   - `${cache}` works wherever `${data}` does. In runs, it's `cache` in the
     app's data directory. In builds, for an SDK's or runtime's own entries,
     it's `B:\cache\<tool id>`: zigsaw keeps it in the store as
     `cache\tools\<id>` and moves it into the build root, once the build has
     `B:`.
   - zig's recipe sets `ZIG_GLOBAL_CACHE_DIR=${cache}`.
   - `prune` reports tool caches, and `--downloads` deletes them.
2. **Vendor steps, aliases, and the Rust SDK.**
   - A probe first, through zigsaw itself: the Rust image, and a recipe
     building ripgrep in two stores. It found that Rust's windows-gnu
     toolchain can't link `windows-sys` alone, and that rustc can't start its
     linker from a path over 260 characters (see Findings).
   - Modules gain `vendor` (`commands`, `dir`, `sha256`). All vendor steps
     run after the downloads and before any module builds, with network
     access. `dir` becomes a tar in the layer format, whose hash is checked
     against the recipe's and which is kept with the downloads. After a fresh
     vendor step, the module's directory and the profile folders start again
     from the sources and that tar, so a build sees the same files whether
     the commands ran or the cache had their result. Configs record the hash
     under `build.vendor`.
   - Images gain `aliases`, shaped like exports. In a build, each alias of
     an SDK or runtime image becomes `B:\bin\<name>.exe`, a copy of
     `zigsaw-shim.exe` whose sidecar holds a command line, first on PATH. The
     shim runs that command line and its caller's arguments as typed. zig's
     image aliases `dlltool` to `zig dlltool`.
   - `recipes/rust.json`: rustc, cargo, the standard library and Rust's
     MinGW linker, 1.99.0, without `rust-lld` and the WebAssembly linker.
   - `.crate` files are read as `tar.gz`.
3. **ripgrep from source, publishing and CI.**
   - `recipes/ripgrep.json` builds 15.2.0 from its crate, with ripgrep's
     own `release-lto` profile, and generates its man page and shell
     completions as its releases do, so the image has the release zip's
     files.
   - The published recipes are listed in dependency order: zig before SQLite
     and ripgrep, Rust before ripgrep. The matrix builds zig and Rust before
     ripgrep. CI's timeout went from 45 to 60 minutes.

### Code map

Changed since iteration 4:

| Area | Changes |
|---|---|
| Formats | `oci.zig`: `${cache}`, `aliases`, `build.vendor`. `recipe.zig`: `vendor`, `aliases`, `.crate` |
| Building | `builder.zig`: tool caches moved in and out, alias shims in `B:\bin`, vendor steps |
| Shims | `shim.zig`, `Sidecar.zig`: the alias form of a sidecar |
| Running | `run.zig`: `${cache}` for an app and its runtimes |
| Store | `cache\tools\<id>`, and `prune` for it |
| Recipes | `rust.json` (new), `ripgrep.json` from source, zig's cache and alias |
| Tests | `tests/build.sh`: tool caches, aliases, vendor steps, a Rust fixture in `tests/build/rust/` |

About 7,500 lines of Zig in `src/` (7,100 after iteration 4). Still no
dependencies beyond the Zig 0.16 standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 47 of 47 pass (45 after iteration 4) |
| [`tests/build.sh`](../tests/build.sh) | 58 checks (45 after iteration 4). The last full run passed 57; the 58th was a test that wrongly expected a pinned vendor step to run its commands when the unpinned run before had already cached their result. Fixed, and the vendor checks pass on their own |
| [`tests/shims.sh`](../tests/shims.sh) | 17 of 17 pass, after the shim gained its alias form |
| [`tests/matrix.sh`](../tests/matrix.sh) | ripgrep's checks, with the source-built rg: as intended in both sandboxes. The rest wasn't run this iteration |
| [`tests/store.sh`](../tests/store.sh), [`ctrlc.sh`](../tests/ctrlc.sh) | 15 and 20 checks, all pass (`prune` and the shim changed). `batch.sh` and `registry.sh` weren't run: the code they cover didn't change |
| [`tests/published.sh`](../tests/published.sh), locally | 46 of 46 pass. All nine published images have the digests of fresh builds, and the Rust image's 649 MB layer went up in one request |
| Reproduce workflow on GitHub | Not checked from here: the repository is private, and `gh` isn't installed |

New checks in `tests/build.sh`:

- a warm rebuild of the C fixture makes the same image as the cold build
- zig run as an app keeps its cache in its data directory
- a tool's `${cache}` is `B:\cache\<id>` in builds, and kept between them
- a tool's alias runs its command with its arguments, then the caller's
- `prune` keeps tool caches, and `--downloads` deletes them
- an unpinned vendor step fails, naming the hash to pin
- a pinned one builds offline from what it fetched, without what its
  commands left outside `dir`, and the config records it
- a vendor step that makes something else fails, naming both hashes
- with the server gone, a rebuild takes the vendored files from the cache
- the Rust image builds; a Rust program using `windows-sys` builds with its
  crates vendored and zig's `dlltool`, runs, and builds again to the same
  image

Checked by hand:

- **ripgrep in two stores at different paths:** same image, once with
  `cargo vendor` run fresh in the second store.
- **ripgrep with and without `rust-lld` in the Rust image:** same `rg.exe`.
- **The other published images** (BusyBox, MinGit, Node, Prettier, Python)
  rebuild to their published digests: the new config fields are left out
  when empty.

### Measurements

On the development machine:

| What | Time |
|---|---|
| The C fixture, cold, then with zig's cache kept | 28–30 s, then 0.4–1 s |
| SQLite, cold, then `--rebuild` | 42 s, then 2 s |
| zig's cache after one C build | 58 MB, 1,694 files |
| Rust image: 4 tarballs, 150 MB of xz | built in 62 s, 55 s of it decompressing; deployed in under 1 s |
| Rust image's layer | 649 MB (878 MB with `rust-lld` and the WebAssembly linker) |
| ripgrep's vendor step | 34 s; 2,792 files, 60 MB |
| ripgrep, with vendoring / with the vendored crates cached | 131 s / 72–93 s |
| `tests/published.sh`, nine images, with the builds cached | 248 s, mostly pulling |

## Decisions made along the way

- **Aliases are shaped like exports**, and named for builds only: they go on
  a build's PATH, never on the user's. Of two images aliasing one name, the
  one listed first in the recipe wins, as on PATH.
- **The Rust image's PATH is only `bin`.** Putting its `self-contained`
  directory on PATH would have found `dlltool` there, but that `dlltool`
  needs an assembler anyway, and rustc finds its linker without it.
- **The Rust image leaves out `rust-lld`, `gcc-ld\` and
  `wasm-component-ld.exe`**, which windows-gnu builds don't use: 229 MB less
  to push and pull, and ripgrep builds the same without them.
- **ripgrep comes from its crate on crates.io**, rather than GitHub's tag
  archive: crates are immutable, the index records their sha256, and a
  binary crate includes its `Cargo.lock`.
- **A vendor step's result is kept under its actual hash**, as downloads
  are, so pinning the hash a failed build printed doesn't run the commands
  again.
- **All vendor steps run before any module builds**, so a wrong hash fails
  at once, not after a long compile. Vendor commands see the module's
  sources and the SDK, not what earlier modules installed.
- **After a fresh vendor step, the profile folders start again too**, not
  only the module's directory: cargo's registry cache in the build's home
  would otherwise be there in a fresh build and missing in one from the
  cache.
- **Tool caches move into a build only once it has `B:`**, so builds also
  take turns with them. If one can't be moved back (a build in another
  logon session put its own back first), it goes with the build root.
- **No new config type for `${cache}`, `aliases` or `build.vendor`.** An
  older zigsaw passes `${cache}` through literally, and ignores the rest;
  there are no released versions to protect. The new fields are left out
  when empty, so other images keep their digests.

## Bugs found

In zigsaw: none outside new code.

Caught in new code and tests before their slice was done:

- The pinned-vendor check couldn't fail the way it meant to: the unpinned
  build before it had already cached the vendored files. It now deletes them
  first.
- BusyBox's sh shows paths in variables with `/` (`B:/cache/...`), which a
  new check compared against `\`.

## Findings

- **zig's cache can be kept between builds.** On `B:\cache`, a warm C build
  took 0.4 s instead of 30, and four build roots of different lengths, two
  cold and two warm, made identical executables. Renaming the cache
  directory in and out right after zig exits works.
- **Rust's windows-gnu toolchain can't link most current Rust programs on
  its own.** `windows-sys` from 0.60 on links Windows' functions with
  `raw-dylib`, and for that rustc runs GNU `dlltool`, which runs GNU's
  assembler. `rust-mingw` ships `x86_64-w64-mingw32-gcc`, `ld` and
  `dlltool`, but no assembler, so the build fails with
  `dlltool.exe: CreateProcess` (rust-lang/rust#103939, #140704).
  - rustc looks for `dlltool.exe` on PATH, and `-C dlltool=<path>` is stable.
  - LLVM's `dlltool` (`zig dlltool`) needs no assembler, accepts the GNU
    `dlltool` arguments rustc passes, and writes import libraries GNU `ld`
    links correctly: ripgrep built with it searches files as it should.
  - A copy of `zig.exe` named `dlltool.exe` doesn't act as `dlltool`: zig
    doesn't choose its command by its own name.
- **rustc can't start a program whose path is longer than 260 characters.**
  It starts its self-contained linker by its full path in the Rust image's
  deployment, which in a store more than about 107 characters deep fails as
  "linker `x86_64-w64-mingw32-gcc` not found". Git Bash starts the same
  file fine.
- **Rust builds reproduce without extra flags.** Crates' source paths are
  relative to the project (`vendor\winapi-util\src\win.rs`), the standard
  library's are `/rustc/<commit>/...`, and MinGW's `ld` takes the PE
  timestamp from `SOURCE_DATE_EPOCH` (1980-01-01). Two stores at different
  paths, builds minutes apart, made the same image.
- **`cargo vendor --locked` reproduces:** run fresh in another store, it
  made the tree whose hash the first had pinned.
- **ripgrep's man page date is its release date** (2026-07-15), not the
  build's, so generating it at build time is deterministic.
- **The Rust image is 649 MB but only about 190 files**, so it deploys in
  under a second, unlike zig's 19.5k files.

## Upstream issues

Nothing new to report; both Rust problems are known or arguably by design:

1. **windows-gnu `raw-dylib` needs an assembler Rust doesn't ship**
   (rust-lang/rust#103939, #140704, still open).
2. **rustc's linker path is limited to 260 characters.** Worth reporting if
   it isn't known: Windows can start such programs when given the `\\?\`
   form of the path.

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
  - Rust builds need zig in their SDK, for `dlltool`.
  - Only `x86_64-pc-windows-gnu` is set up, and crates that compile C (the
    `cc` crate) find no C compiler.
  - The store's path must be shorter than about 100 characters.
- **Registries.** Pushing an image uploads each layer in one request (the
  Rust image's is 649 MB), and an app's runtime layers go to the app's
  repository even when the registry has them elsewhere. Layers aren't
  compressed.
- The gaps from earlier iterations remain: commands installed at run time
  aren't on PATH, AppContainer compatibility, the registry isn't isolated,
  logins don't come from Docker's configuration, and runtimes can't have
  runtimes.

Not yet tested:

- The Reproduce workflow for this iteration's commits: the first build of
  the Rust image and ripgrep, and the first `cargo vendor`, on another
  machine.
- The whole matrix, `tests/registry.sh` and `tests/batch.sh` with this
  iteration's zigsaw.

## Suggested for iteration 6

1. **More of zig as aliases:** `cc`, `c++`, `ar` and `rc` would give Rust
   crates that compile C (`cc`) a compiler, and CMake a one-word compiler.
2. **Go**, now that vendor steps exist: `go mod vendor` fits them as
   `cargo vendor` does, and Go builds need no linker of their own.
3. **CMake and Ninja**, for C and C++ projects beyond hand-written commands.
4. **Cheaper pushes and pulls:** chunked uploads for layers like Rust's,
   cross-repository mounts for runtimes' layers, perhaps compression.
5. **Shorter deployment paths**, such as a shorter digest prefix, to keep
   tools like rustc under Windows' path limit in deeper stores.
6. **Shims for commands installed at run time**, and **the end-to-end
   suites in CI**, both still waiting.
