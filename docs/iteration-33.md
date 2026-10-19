# Iteration 33: CI in parallel, and a JavaFX app

Built 2026-10-19, still on Temurin's early-access OpenJDK 25.0.5: the move
to its release is a session of its own (see "For you").

## Outcome

- **The Reproduce workflow checks the published recipes in four parallel
  jobs** instead of one. In iteration 32, one job built all 38 of them, one
  after another, in 37 of its 60 minutes, and every new app added to that.
  - The groups are in
    [`scripts/published-groups.txt`](../scripts/published-groups.txt):
    `c`, `rust-go`, `apps` and `java`, about 4 to 13 minutes of building
    each, and `skip` for GTK's family, which CI leaves out as before.
  - `tests/published.sh` checks one group when `GROUP` is set. It refuses
    to run if a published recipe is in no group or in two, so a new recipe
    can't go unchecked.
  - The end-to-end suites run in a job of their own, beside the groups, in
    a store of the published images that
    [`tests/seed-store.sh`](../tests/seed-store.sh) pulls (or builds, for a
    version not published yet). The group jobs check that those images are
    what the recipes build.
  - A run should take about 20 minutes instead of 44: the longest job is
    now `build` (tests/build.sh, 19 minutes), which this iteration leaves
    as it was. Not seen yet: the first run is after your push.
- **Scene Builder 26.0.0** (`com.gluonhq.SceneBuilder`, Flathub's id),
  Gluon's designer for JavaFX user interfaces, is built from source with
  Maven, and brings OpenJFX 26.0.2 itself (your pick over a shared OpenJFX
  image).
  - In soft, low and AppContainer runs, it opens a layout given with
    `--file`, drawing with Direct3D, or in software where there's none.
  - Its recent files and window layouts stay with the app.
  - Explorer offers it for `.fxml` files, and it has a Start menu shortcut.
- **No zigsaw change**, so no release.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-33-wild-beacon.md`):

- **CI headroom**, and **a JavaFX app**: Scene Builder, over PDFsam Basic.
  Not picked: `jlink` runtimes, ZLS.
- OpenJFX **bundled in the app**, over an OpenJFX runtime image.
- The re-pin to Temurin 25.0.5's release stays a separate session. Scene
  Builder is on 25.0.5 early access like the other Java images, and joins
  that re-pin.

## What was built

### CI

- [`scripts/published-groups.txt`](../scripts/published-groups.txt): each
  published recipe in one group (`<group>: <recipe>...`), balanced on the
  minutes iteration 32's run spent on each recipe.
- [`tests/published.sh`](../tests/published.sh):
  - `GROUP=<name>` checks only that group's recipes, still in the order of
    `published-recipes.txt`;
  - every run first checks that the groups cover each published recipe
    exactly once, and nothing else;
  - the catalog and redirect checks cover the group's apps.

  A group's builds pull the images they pin that other groups build, as
  any fresh store does, so the groups needn't follow dependencies.
- [`tests/seed-store.sh`](../tests/seed-store.sh):
  - `--pull` recipes are pulled at their version, or built when that
    version isn't published;
  - `--build` recipes are built, so that their downloads seed the suites'
    own stores (BusyBox's and Node's).
- [`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml):
  - `groups` lists the groups from the file;
  - `published` is a matrix job over them (`fail-fast: false`, 30
    minutes, logs per group);
  - `suites` seeds its store, then runs store, shims, sandbox, batch,
    ctrlc, install, registry and matrix as before;
  - `pins` and `build` are unchanged.

### Scene Builder

[`recipes/scenebuilder.json`](../recipes/scenebuilder.json):

- **Sources**: the GitHub tag, and Gluon's OpenJFX 26.0.2 SDK for Windows
  into `javafx\`.
- **Vendor step**: `mvn package` into `vendor`, cleaned as PDFBox's is.
- **Build**: offline, with `project.build.outputTimestamp` set to the tag's
  commit time, plus three changes:
  - `maven-compiler-plugin` 3.13.0 → 3.14.1, in the vendor step too;
  - the version without `-SNAPSHOT`, as upstream's release sets it;
  - the About box's build date set to the tag's commit time.
- **The weekly usage report is removed** (an id, the OS and Java's version,
  sent to Gluon at startup). Checking for updates and registering stay in
  the Help menu, and the app has `network`, which its library manager needs
  to search Maven repositories.
- **Its layer**: the app's jar (with its dependencies, not JavaFX), JavaFX's
  jars, DLLs and licences, its licence and its `.ico`.
- **Running**: JavaFX's jars go on the module path and the app's jar on the
  class path, with upstream's installer's Java options.
- **It runs on the JDK's image** (see "Decisions made along the way").
- **The rest**: it keeps
  `HKCU\Software\JavaSoft\Prefs\com\oracle\javafx\scenebuilder`, and has
  the working directory and Desktop, Documents and Downloads.

[`tests/java/hello.fxml`](../tests/java/hello.fxml) is a small layout
written for the tests. [`tests/java.sh`](../tests/java.sh) gets a Scene
Builder section (7 checks):

- the window opening `hello.fxml` given with `--file`, in each sandbox;
- no `.openjfx` unpacked into its data;
- recent files kept in its hive;
- its shim, its shortcut and the `.fxml` registration.

The registry check covers its key too.

Scene Builder is in `scripts/published-recipes.txt`, the `java` group, and
published.sh's apps that must stay up for ten seconds (it has no option
that exits).

Docs: [recipes.md](recipes.md) (Scene Builder, and which Java image an app
needing JDK modules lists), [findings.md](findings.md) (JavaFX), and the
README (CI, the app, Testing).

## Results

### Tests

- `GROUP=apps tests/published.sh`, the smallest group, in a new store:
  98 checks passed, 36 recipes in other groups left out. It took 14
  minutes here, with every download cold; CI took 4 for those recipes.
- The groups check, with a recipe taken out of the file and another put in
  two groups: it names both and stops before building anything. An
  unknown `GROUP` stops it too.
- `tests/seed-store.sh` in a new store built BusyBox and pulled fzf, then
  left both as they were on a second run. A pull of an unpublished
  version fails with "not found", which it takes as "build it".
- `tests/java.sh`: 44/44 in 4.5 minutes, in iteration 32's store (Scene
  Builder built there too).
- Scene Builder by hand:
  - JavaFX on Direct3D 9Ex in soft, low and AppContainer runs;
  - forced to software (`-Dprism.order=sw`, as on a runner without a GPU)
    in an AppContainer;
  - windows open in 3 to 4 seconds.
- `scripts/check-pins.sh`: all 99 pins resolve; the only complaint is that
  Scene Builder isn't published yet.
- The workflow itself runs only on GitHub: its first run is after your
  push.

### Reproducibility

| image | manifest | notes |
|---|---|---|
| `com.gluonhq.SceneBuilder` 26.0.0 | `f25d1cd4` | 55 MB layer (118 MB of files, WebKit's DLL 96 MB of them) |

Scene Builder made the same image in two stores: `D:\zs\i33\p`, built
twice, and `D:\zs\i33b\p`, new and empty, where the SDK images came from
ghcr.io and the vendor step fetched everything again (same hash
`28c69952`; 3.5 minutes in all). Maven itself takes 34 s of the build;
most of the rest is compressing the layer.

In CI, Scene Builder adds about 3 minutes to the `java` group (some 13).

## Decisions made along the way

- **The JDK's image as Scene Builder's runtime** (asked at the probe's
  gate):
  - Temurin's JRE has no `jdk.unsupported.desktop`, which `javafx.swing`
    requires, and Scene Builder lists `SwingNode` among its components at
    startup.
  - The JDK's image (published, `e45ed698`, what Maven runs on) has it.
    It pulls about 33 MB more than the JRE's.
  - Not taken: a `jlink` runtime in the app, or making the JRE image with
    `jlink`. The second fits the re-pin session better, if wanted.
- **OpenJFX from Gluon's SDK zip, not Maven Central's jars** (my call). The
  bundling you picked holds; only the source differs. Maven Central's
  Windows jars carry each DLL inside, so putting the DLLs beside the jars
  would ship them twice (WebKit's alone is 96 MB). The SDK has the jars
  without them, the DLLs in `bin`, and the licences, which is how
  upstream's own installer gets JavaFX (as jmods). It's JavaFX 26.0.2, the
  latest 26 update; Scene Builder compiles against 26.
- **The usage report removed** (my call), as Files' updater was turned off
  in iteration 21. Updates come through zigsaw.

## Known gaps

- Scene Builder's About box says it was built with Java 24 and JavaFX 26:
  its POM's own properties, not the JDK and the JavaFX that run it.
- Still on OpenJDK 25.0.5 early access (below).

## For you

1. Publish Scene Builder: `scripts/publish.sh recipes/scenebuilder.json`.
   It pushes the catalog and runs the pin check last.
2. Make the `com.gluonhq.scenebuilder` package public.
3. Commit and push. I then check the Reproduce run: four `published` jobs,
   `suites` and `build` green, and how long each took.
4. **When Temurin releases 25.0.5**, ask me to re-pin. That's now eight
   images: JDK, JRE, Maven, Gradle, PDFBox, PlantUML, Logisim, Scene
   Builder.

## Suggested for iteration 34

- The Temurin 25.0.5 re-pin above.
- Split `tests/build.sh` across jobs too, now the longest at 19 minutes.
- `jlink` runtimes made for each Java app (Scene Builder would need
  `jdk.unsupported.desktop` in its own).
- ZLS from source, with a vendor step for zig's package manager.
- GTK's family back in CI as a group of its own, now that a group costs a
  job rather than minutes of one.
