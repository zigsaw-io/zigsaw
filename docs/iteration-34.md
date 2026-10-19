# Iteration 34: Scene Builder on any time zone, build.sh in parallel, and ZLS

Built 2026-10-19. Temurin's OpenJDK 25.0.5 still isn't released (Adoptium's
latest is 25.0.4.1), so the Java images stay on its early access, and the
re-pin stays a session of its own.

## Outcome

- **Iteration 33's Reproduce run was red**, on one check: Scene Builder
  built on the runner differed from the image published from here.
  - The cause was the time zone. Its jar with dependencies is made by
    maven-shade-plugin 3.2.4, which writes some dependencies' entry times
    in the JVM's zone: here UTC+7, on the runner UTC.
  - The recipe now runs its build's JVM on UTC. This machine then builds
    the runner's image, `db425890`, which you republish.
- **`tests/build.sh` runs in four parallel jobs**, like the published
  recipes since iteration 33. It was the longest job, 22 of the run's 23
  minutes.
  - Its groups are listed in the script: `base`, `zig`, `cmake-meson` and
    `langs`. `GROUP=<group>` runs one, and `--groups` lists them.
  - The base group's job runs the unit tests too.
  - A run should take about 13 minutes, the longest published group's.
    Not seen yet: the first run is after your push.
- **ZLS 0.16.1** (`org.zigtools.zls`), the Zig language server, is built
  from source with `zig build`. Its packages are fetched by a vendor step
  that pins zig 0.16's `zig-pkg` directory.
  - It runs on zig's image, which it finds on its PATH.
  - In soft, low and AppContainer runs, a session over stdio shows the
    standard library's documentation, learns the modules a project's
    `build.zig` declares, and reports a syntax error.
  - Point an editor at its `zls` command.
- **No zigsaw change**, so no release.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-34-adaptive-cocke.md`):

- **Split `tests/build.sh`** and **ZLS from source**. Not picked: GTK's
  family back in CI, `jlink` runtimes.
- Scene Builder's fix first, whatever else.

## What was built

### Scene Builder

[`recipes/scenebuilder.json`](../recipes/scenebuilder.json): the module's
env sets `JDK_JAVA_OPTIONS=-Duser.timezone=UTC`, which every JVM the build
starts reads (Maven's, here), beside the JDK image's `JAVA_TOOL_OPTIONS`.

### tests/build.sh in groups

- [`tests/build.sh`](../tests/build.sh):
  - each section is guarded by `if section <name>`;
  - a table at the top puts each section in one group, which the script
    checks before anything else (a section in no group, in two, or a name
    that isn't a section stops it);
  - without `GROUP`, everything runs, as before.
- What sections took from earlier ones, they now find in the preamble:
  - BusyBox's image, which nearly all build with;
  - `rebuilt_manifest` and `free_afterwards`;
  - `need_zig`, which builds zig's image once for the sections that use it
    (build commands, CMake, Meson, Rust, Go).
- CMake and Meson moved out of `build commands` into sections of their own,
  after it.
- The cleanup removes every app in the store's `refs`, rather than a list
  of ids that a group might not have set, and checks that none is left.
- [`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml):
  - the `groups` job also lists build.sh's groups (`--groups`, on Linux);
  - `build` is a matrix over them (`fail-fast: false`, 25 minutes, logs per
    group);
  - the unit tests run in `build (base)` only.

### ZLS

[`recipes/zls.json`](../recipes/zls.json):

- **Sources**: the GitHub tag.
- **Vendor step**: `zig build --fetch`, pinning `zig-pkg` (known-folders,
  diffz, lsp-kit; tracy is lazy and not needed).
- **Build**: `zig build --system zig-pkg -Doptimize=ReleaseSafe
  -Dcpu=baseline -Dstrip -Dversion-string=0.16.1`.
  - `--system` builds offline from the vendored packages.
  - `-Dcpu=baseline`, as zigsaw's own releases, so the image doesn't depend
    on the build machine's CPU.
  - The version string spares its build a `git describe`.
- **Running**: zig's image is its runtime (also on the build's PATH, so it
  isn't in the SDK too), with `${zig}` on ZLS's PATH. It has the working
  directory.

[`tests/zls.sh`](../tests/zls.sh) (19 checks, under half a minute) holds a
session with ZLS as an editor does, in each sandbox, on a small project in
[`tests/zls/`](../tests/zls/): hover on `std.debug.print`, hover on a
function of a module only `build.zig` names (asked again each second while
ZLS runs `build.zig`), diagnostics for a file that doesn't parse, and a
clean exit. Then `--version`, its caches in its data, and its shim. The
`suites` job runs it on the published image.

ZLS is in `scripts/published-recipes.txt`, the `c` group, and the catalog.

Docs: [recipes.md](recipes.md) (Zig, ZLS, vendor steps, Scene Builder),
[findings.md](findings.md) (zig's packages and ZLS, Scene Builder's time
zone), and the README (the app, CI, Testing).

## Results

### Tests

- `tests/build.sh`, each group alone in a new store, downloads seeded from
  another store's:

  | group | checks | here |
  |---|---|---|
  | `base` | 84 | 41 s |
  | `zig` | 34 | 5 min |
  | `cmake-meson` | 10 | 6 min |
  | `langs` | 52 | 10 min |

  No check failed. On a runner, without seeded downloads, the sections took
  about 2, 7, 7 and 9 minutes in iteration 33's single job; each job adds
  its setup (about a minute and a half, BusyBox's image included).
- `tests/build.sh --groups` lists the four, an unknown `GROUP` stops it,
  and a section taken out of the table, or put in two groups, is named
  before anything runs. A run of all of it at once wasn't repeated: it
  runs the same sections, in the same order but for CMake and Meson.
- `tests/zls.sh`: 19/19 in 27 s.
- `scripts/check-pins.sh`: all 101 pins resolve; the only complaint is that
  ZLS isn't published yet. published.sh's groups check passes with ZLS in
  `c`.
- The workflow itself runs only on GitHub: its first run is after your
  push.

### Reproducibility

| image | manifest | notes |
|---|---|---|
| `com.gluonhq.SceneBuilder` 26.0.0 | `db425890` | the runner's image; layer `13a21462`, 55 MB |
| `org.zigtools.zls` 0.16.1 | `aa23bf91` | layer `1efd78c4`, 1.5 MB; vendor `4f200d86` |

- Scene Builder made `db425890` here with the fix, in iteration 33's store
  and in a new one, where the vendor step ran again from the network, under
  the new env, to the same pinned hash. Before the fix, the same build with
  the JVM put on UTC by hand made it too, which is how the time zone was
  confirmed.
- ZLS made the same image built again and in a new store, where the vendor
  step fetched its packages again (`D:\zs\i34\p` and `D:\zs\i34\r`).

## Decisions made along the way

- **Scene Builder's JVM on UTC, in the recipe** (my call), rather than a
  newer maven-shade-plugin (which honours `project.build.outputTimestamp`
  from 3.3.0) or `-Duser.timezone=UTC` in the Maven image's build alias.
  - A newer shade would change the vendor step and the jar's contents.
  - The alias would cover every Maven build, but means republishing Maven
    and what pins it; it fits the Temurin re-pin session, which republishes
    them anyway.
- **`zig-pkg`, not zig's global cache, as the vendor directory** (found at
  the probe). zig 0.16 unpacks packages into the project's `zig-pkg`;
  `--system` reads only those. The plan's `--global-cache-dir vendor`
  would have pinned compressed copies `--system` can't use.
- **zig only as ZLS's runtime**, not also in its SDK: zigsaw refuses one
  alias for both, and runtimes are on the build's PATH anyway.
- **The id `org.zigtools.zls`**, after the project's domain (zigtools.org).

## Known gaps

- ZLS reaches files outside the working directory only with an override
  (`zigsaw override --filesystem=<dir> org.zigtools.zls`).
- ZLS 0.16 needs zig 0.16.x; when zig's image moves to 0.17, ZLS moves with
  it.
- Still on OpenJDK 25.0.5 early access.

## For you

1. Publish Scene Builder again and ZLS:
   `scripts/publish.sh recipes/scenebuilder.json recipes/zls.json`. It
   pushes the catalog and runs the pin check last.
2. Make the `org.zigtools.zls` package public.
3. Commit and push. I then check the Reproduce run: `published (java)`
   green again, the four `build` jobs, and how long each job took.

## Suggested for iteration 35

- The Temurin 25.0.5 re-pin, when it's released (eight images, now with
  Scene Builder's new digest).
- GTK's family back in CI, as groups of its own.
- `jlink` runtimes made for each Java app.
- Incremental `zigsaw build` of projects (keeping `.zig-cache`).
