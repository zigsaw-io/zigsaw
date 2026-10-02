# Iteration 4: real builds and runtimes

Concluded 2026-10-03.

## Outcome

After iteration 3, a zigsaw image was little more than a manifest for a bundle
of downloaded binaries: a recipe listed files to download, and the build
packed them into one layer. Nothing was compiled, no command ran at build
time, and an app couldn't depend on another image. Iteration 4 redesigned the
recipe and image formats around the two things Flatpak has and zigsaw
lacked. Zigsaw now:

- runs apps on **runtimes**: separate images, pinned by digest, whose files
  travel in the app's image as a layer of their own. Prettier runs on Node
  this way. Each layer is unpacked once on disk, shared by every app that uses
  it, and removing Node as an app doesn't affect Prettier;
- **builds from source**: a recipe's modules can run build commands in a
  build sandbox, with pinned SDK images (zig as the C compiler, BusyBox as the
  shell and toolbox) on PATH. SQLite and zlib build from source this way;
- makes those builds **reproduce**: the build runs on a fixed drive, `B:`, so
  paths compiled into executables are the same on every machine. Two stores
  at different paths build the same SQLite image;
- can use the machine's **MSVC** when a recipe asks for it, and records that
  the image won't reproduce elsewhere;
- **reuses builds** whose inputs haven't changed.

All eight published images, Prettier, zig and SQLite included, have the
digests of fresh builds of their recipes.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Dependency model | Flatpak's split. Libraries are modules built into the app. Runtimes and toolchains are separate images pinned by manifest digest. A runtime's layer travels in the app's manifest, so one pull gets everything, and each layer is unpacked once, shared |
| Toolchain | Hermetic SDK images by default: zig (clang as `zig cc`) and BusyBox. Host MSVC is opt-in per recipe, and the image is marked as built with a host toolchain |
| Prebuilt binaries | Kept: a module without build commands places its sources, on the streaming path. Node, Python, Git and zig stay repackaged official builds |
| Network during builds | Off by default, opt-in per module, recorded in the image. Discouraged with proxy variables, not enforced |
| Formats | Recipe v2 (`modules`, `sdk`, `runtimes`, `cleanup`), and a v2 config type so older zigsaw versions refuse new images. v1 images are still read |

The decisions of iterations 1–3 still hold.

## What was built

The iteration ran as three slices, each ending in working, tested code.

1. **Image format v2 and runtimes.**
   - The config type is `application/vnd.zigsaw.app.config.v2+json`. It
     gains `runtimes` (each runtime's id, version, image, layer, and its own
     `path` and `env`), `args` for the app's command, and `build`: a record of
     the source hashes, SDK images, network use and host toolchains.
   - Manifest layers are each runtime's layer, in config order, then the
     app's own. `pull` and `push` already moved every layer, so a pull brings
     the runtime along without installing it as an app.
   - Deployments are keyed by layer digest instead of manifest digest, so an
     app and the apps using it as a runtime share files.
   - Runs put a runtime's PATH entries after the app's, and set its variables
     before the app's. `${node}` stands for the runtime's directory in
     commands, exports, `path` and `env`.
   - Recipes list `modules` and pin `runtimes` and `sdk` by digest. A missing
     digest fails the build and prints the one to pin, as a missing source
     hash does. Sources gain `tar`, `tar.gz` and `tar.xz` archives, and
     `cleanup` leaves files out of the app.
   - `deps.zig` takes pinned images from the store, built or pulled, or from
     their registry, and keeps them for later builds until
     `prune --downloads`.
2. **Build steps.**
   - A probe settled how builds reproduce (see Findings), before any
     sandbox code was written.
   - Modules with `build` commands get their sources unpacked into
     `B:\src\<module>`, and the commands run there in BusyBox's `sh` or, with
     `"shell": "cmd"`, in cmd.exe. Each install into `B:\prefix`, which becomes
     the app's layer. Commands get an environment built from scratch with a
     fresh profile, a fixed `SOURCE_DATE_EPOCH`, proxy variables pointing
     nowhere unless the module has `"network": true`, and a job object.
   - `drive.zig` maps the build directory to `B:` with `DefineDosDeviceW`, as
     `subst` does, without admin rights. Builds take turns through a named
     mutex, a mapping left by a crashed build is replaced, and anyone else's
     `B:` fails the build.
   - Builds without build commands keep the streaming path, so repackaged
     apps build as fast as before.
   - `zigsaw build --keep-build-dir` keeps the build directory to inspect.
   - `recipes/sqlite.json` builds zlib and SQLite with the zig and BusyBox
     images as its SDK.
3. **MSVC, build cache, CI and publishing.**
   - `"host": ["msvc"]` finds the newest Visual Studio with the C++ tools
     with `vswhere` (prereleases included), runs `vcvars64.bat`, and adds what
     it set to the build environment. `build.host` records the MSVC and
     Windows SDK versions, and installing the image warns about them.
   - `cache\builds\<hash>` remembers which image a build made, keyed by the
     recipe's bytes, its local sources and zigsaw's own executable. An
     unchanged build, including `zigsaw update` of an app built from a
     recipe, reuses that image. `--rebuild` builds anyway. MSVC builds are
     never reused.
   - zig, as an SDK image, and SQLite joined the published recipes, listed
     after what they depend on, so `tests/published.sh` builds them in one
     store. CI's timeout went from 30 to 45 minutes.

### Code map

New since iteration 3:

| Area | Modules |
|---|---|
| Formats | `oci.zig` (v2 config, runtimes, layer checks), `recipe.zig` (modules, `sdk`, `runtimes`, `cleanup`, `host`) |
| Dependencies | `deps.zig` |
| Building | `builder.zig` (both paths, the build cache), `Tree.zig` (moved out of `builder.zig`: source trees, tar sources, layers, trees to and from disk), `drive.zig`, `msvc.zig` |
| Running | `environment.zig` (moved out of `run.zig`, shared by runs and builds), runtimes in `run.zig` |
| Store | deployments per layer, `cache\images`, `cache\builds`, and a `deleteTree` that copes with Windows' directory links |
| Tests | `tests/build.sh` with fixtures in `tests/build/` |

About 7,100 lines of Zig in `src/` (5,400 after iteration 3). Still no
dependencies beyond the Zig 0.16 standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 45 of 45 pass (34 after iteration 3) |
| [`tests/build.sh`](../tests/build.sh) (new) | 45 of 45 pass in about 4 minutes. 17 cover runtimes, 23 build commands, the build cache and SQLite, and 5 MSVC (skipped without Visual Studio) |
| [`tests/matrix.sh`](../tests/matrix.sh) | `soft`: all 28 as intended. `appcontainer`: the same 11 known failures as before. It now stops each step after 120 s, and takes 30 s with warm caches |
| [`tests/shims.sh`](../tests/shims.sh), [`store.sh`](../tests/store.sh), [`ctrlc.sh`](../tests/ctrlc.sh), [`batch.sh`](../tests/batch.sh) | 17, 15, 20 and 11 checks, all pass. `store.sh`'s test versions now differ in a file too: versions with the same files now share a deployment |
| [`tests/registry.sh`](../tests/registry.sh) against two zot registries | 39 of 39 pass. 4 are new: an app with a runtime goes to a registry and into an empty store, and runs there |
| [`tests/published.sh`](../tests/published.sh), locally | 41 of 41 pass. All eight published images have the digests of fresh builds |
| Reproduce workflow on GitHub | Not checked from here: the repository is private, and `gh` isn't installed |

`tests/build.sh` builds the same C app, which embeds its source path, in two
stores at different paths, and compares the digests. It also checks the build
drive (taken, stale, two builds at once), failing commands, network access
with and without opting in, links left in the prefix, and a build whose
output pipe closes early.

Checked by hand:

- **SQLite in two stores at different paths:** same digest.
- **The probe:** see Findings.

### Measurements

On the development machine:

| What | Time |
|---|---|
| Build zlib and SQLite from source | 41–44 s, about 30 s of it zig building its C runtime |
| The same recipe again (build cache) | under 1 s |
| `zig cc`, first use in a fresh profile, then again | about 30 s, then under 1 s |
| Build a C program with MSVC | 3 s |
| `tests/published.sh`, eight images, with cached downloads | 162 s |

## Decisions made along the way

- **Prettier, not TypeScript, shows runtimes.** TypeScript 7 is a native
  binary behind a small Node launcher, so it doesn't really run on Node.
  Prettier is pure JavaScript.
- **Versions with the same files share a deployment.** Deployments are per
  layer, so a version bump that changes no file installs nothing new.
- **Images that builds use are kept like downloads.** A runtime or SDK image
  that isn't installed as an app stays until `prune --downloads`, so the
  next build doesn't download zig's 378 MB again.
- **A missing runtime digest suggests the installed app's**, if its version
  is the one named, and otherwise the registry's.
- **No junctions to SDK directories.** zig resolves its real path anyway, so
  SDK and runtime directories go on PATH as they are.
- **The prefix isn't renamed into the deployment.** Installing unpacks the
  layer, as for any image. It's simpler, and certainly the same files.
- **The SDK is only unpacked when there's something to build with it**, and
  all downloads are fetched before anything builds, so a wrong hash fails
  the build at once.
- **The build cache's key includes zigsaw's own executable**, so any change
  to zigsaw builds again. `--keep-build-dir` always builds.
- **zig recipes pass `-target x86_64-windows-gnu` and `-s`** (see Findings).
- **zigsaw writes to stderr itself**, ignoring failures, rather than through
  `std.debug.print` (see Upstream issues).
- **A run ends whatever the app left running before zigsaw returns**,
  rather than when the job closes, so nothing it started holds files after
  zigsaw is done.
- **`vcvars64.bat` runs with the Visual Studio installer on PATH and
  telemetry off.** VS 18's scripts call `vswhere` by name. cmd's `set`
  output is captured as UTF-16 (`cmd /u`).
- **Under `zig build test`, `fail` logs at debug level**, since the test
  runner counts error logs as failures and tests fail things on purpose.

## Bugs found

In zigsaw:

- **zigsaw crashed when nobody read its stderr any more**, as in
  `zigsaw build ... | head`. During a build, that left `B:` mapped and the
  build directory behind. The crash is in Zig's `std.debug.print` (see
  Upstream issues); zigsaw no longer uses it.
- **Deleting a directory that a WinINet user had written to failed.** Build
  directories stayed behind after MSVC builds, and an app's data directory
  would have too. Zig's `deleteTree` can't delete the directory link WinINet
  leaves in a profile; zigsaw now removes such links itself.

Caught in new code before its slice was done:

- The build cache made two checks vacuous: the "builds wait for `B:`" and
  closed-pipe checks reused an earlier build instead of building. Both now
  pass `--rebuild`.
- SDK images were unpacked even for recipes without build commands.

## Findings

- **What makes `zig cc` output differ between builds:**
  - **Paths:** `__FILE__`, in `assert` among others, records the path the
    compiler was given. Mapping the build to `B:` makes the paths the same:
    two directories of different lengths gave identical executables.
    `-ffile-prefix-map` works too, but each recipe has to pass it.
  - **PDBs:** `zig cc` writes a PDB with every executable, even with `-g0`.
    The PDB names randomly named temporary object files, and the executable
    carries the PDB's signature, so no two builds match. `-s` turns it off.
  - **The target:** without `-target`, `zig cc` builds for the machine it
    runs on, CPU features and Windows version included. Builds on another
    machine differ, and the result may not run on older CPUs.
  - **Dates:** zig refuses `__DATE__` and `__TIME__` (`-Werror=date-time`).
    With `SOURCE_DATE_EPOCH`, they're fixed.
  - **zig's location doesn't matter:** zig from the store and from WinGet
    built identical stripped executables.
- **`zig cc` builds its MinGW C runtime on first use**, about 30 s, and
  caches it in the profile. Since every build starts with a fresh profile,
  every build pays it.
- **BusyBox's `make` (pdpmake)** treats zlib's `%.o: %.S` rule as replacing
  `%.o: %.c`, then falls back to its built-in rule, and `zig cc -c` without
  `-o` writes `.obj`. zlib's recipe compiles with a shell loop instead.
- **WinINet leaves a dangling directory symbolic link,
  `INetCache\Content.IE5`, in the profile of whatever uses it**, with the
  system and hidden attributes (0x2416). `RemoveDirectoryW` removes the link
  itself.
- **cl.exe starts `vctip.exe`**, Visual Studio's telemetry tool, which uses
  WinINet; that's what created the link above in build profiles.
- **Proxy variables do keep the usual tools off the network.** BusyBox's
  `wget` fails through `http://127.0.0.1:9` and works without it, against a
  local `busybox httpd`.

## Upstream issues found

Two more in Zig 0.16's standard library, worked around in zigsaw and worth
reporting:

1. **`std.debug.print` crashes with an access violation on Windows** once
   stderr is a pipe whose reader has exited. The first write fails quietly,
   and a later one crashes, despite its documented "ignoring errors".
2. **`Dir.deleteTree` fails with AccessDenied** on a dangling directory
   symbolic link with the system and hidden attributes, such as WinINet's
   `Content.IE5`. `RemoveDirectoryW` deletes it.

## Known gaps

- **Builds.**
  - Network access during builds is discouraged by proxy variables, not
    blocked.
  - Every build starts with fresh profile folders, so zig rebuilds its C
    runtime each time: about 30 s.
  - Builds need `B:` free, and run one at a time.
  - Only x64 MSVC builds are set up, and MSVC images don't reproduce on
    other machines.
- **Runtimes** can't have runtimes of their own.
- **Registries.** Pushing an app uploads its runtimes' layers to the app's
  repository, even when the registry has them in another, and in one request
  (zig's layer is 378 MB). Layers aren't compressed.
- The gaps from iteration 3 remain: commands installed at run time aren't on
  PATH, AppContainer compatibility, the registry isn't isolated, and logins
  don't come from Docker's configuration.

Not yet tested:

- SQLite's build on GitHub's runner: whether the Reproduce workflow is green
  for this iteration's commits.
- MSVC on any machine but the development one.
- `tests/build.sh` in CI.

## Suggested for iteration 5

1. **A tool cache for builds.** zig's C runtime cache is content-addressed
   and safe to share between builds, which would save about 30 s per build.
2. **More apps from source**, with more SDK images: CMake, Rust or Go
   toolchains. Each widens what recipes can build, and tests the build
   sandbox further.
3. **Cheaper pushes and pulls:** cross-repository blob mounts for runtime
   layers, chunked uploads, and perhaps compressed layers, if their digests
   can stay reproducible.
4. **The end-to-end suites in CI**, including `tests/build.sh`, now that
   builds need `B:` and the zig image.
5. **Shims for commands installed at run time**, still the most common
   friction for Node users.
