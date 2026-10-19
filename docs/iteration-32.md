# Iteration 32: Maven's vendor step, and Logisim-evolution

Built 2026-10-19, on Temurin's early-access OpenJDK 25.0.5 like iteration
31; the move to its release is left for when Temurin publishes it (see "For
you").

## Outcome

- **CI's red run is explained and fixed.** Iteration 31's Reproduce run
  failed on PDFBox and build.sh's Maven project: their vendor steps kept
  `.meta/prefixes-central.txt`, the list of group prefixes Maven 3.10
  fetches from each repository, which Maven Central regenerates. The vendor
  steps now delete `.meta`. PDFBox's new vendor tree is the old one less
  those four files, and its layer is unchanged; only its config (which names
  the vendor hash) is new, so it needs republishing.
- **Logisim-evolution 5.0.0** (`com.github.reds.LogisimEvolution`, Flathub's
  id) is built from source with Gradle, on Java's runtime. It's a bigger
  Gradle build than PlantUML's: Kotlin build script, configuration cache,
  three plugins from Gradle's plugin portal, Checkstyle resolved while
  Gradle configures, and a source set that runs during the build. It built
  offline the first time, with no change to zigsaw, Gradle's image or
  `gradle-vendor`. It runs in all three sandboxes:
  - from the command line, `logisim --tty table` simulates a circuit
    without a window;
  - `logisim-gui` opens its window, which Explorer offers for `.circ`
    files;
  - its preferences (recent files) stay with the app.
- **No zigsaw change**, so no release. v0.31.0 is still to be tagged (see
  "For you").

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-32-wobbly-turtle.md`):

- Fix the Maven vendor drift first; PDFBox is republished.
- The new app is a bigger Gradle build, Logisim-evolution, over a JavaFX
  app, `jlink` runtimes or ZLS.
- Move to Temurin 25.0.5's release within the iteration if it came out
  (it didn't).

## What was built

- [`recipes/pdfbox.json`](../recipes/pdfbox.json) and the Maven project in
  [`tests/build/maven`](../tests/build/maven): `rm -rf vendor/.meta` after
  the vendor step's `find`, new vendor hashes.
- [`recipes/logisim-evolution.json`](../recipes/logisim-evolution.json):
  - from the GitHub tag's tarball;
  - vendor step `gradle -g gradle-home shadowJar`, then
    `gradle-vendor gradle-home vendor` (350 files);
  - build `gradle --offline shadowJar` against the vendored repository;
  - the jar, `LICENSE.md` and upstream's `.ico`, which the shortcut and the
    `.circ` association use;
  - keeps `HKCU\Software\JavaSoft\Prefs\com\cburch\logisim`;
  - the working directory and Desktop, Documents and Downloads.
- Upstream's `genBuildInfo` writes the time of the build into the program,
  as a number and as text in the build machine's time zone. The recipe
  replaces both with the tag's commit time in UTC (2026-09-12T04:03:35Z),
  checking that all four replacements applied, so `--version` says when the
  release was made.
- [`tests/java/half-adder.circ`](../tests/java/half-adder.circ): A XOR B and
  A AND B, written by hand for the tests.
- [`tests/java.sh`](../tests/java.sh) gets a Logisim section (10 checks):
  - the truth table from `--tty table` in each sandbox;
  - the version line;
  - the window opening a circuit given with `--file` in each sandbox;
  - recent files kept in its hive;
  - its shims, its shortcut and the `.circ` registration.
  
  The registry check now covers Logisim's key too.
- Logisim is in `scripts/published-recipes.txt`, so CI's published job
  builds it and compares it with ghcr.io. It needs no smoke-test entry:
  `--version` exits 0.
- Docs: Logisim in [recipes.md](recipes.md) and the README, the Maven
  `.meta` note in [recipes.md](recipes.md) and [findings.md](findings.md),
  and Logisim's FPGA tools in [gaps.md](gaps.md).

## Results

### Tests

- `tests/java.sh`: 37/37 in 42 s, with the images already built.
- The Maven project of build.sh, with its new pin, builds and runs. build.sh
  as a whole wasn't run: nothing else in it changed.
- `scripts/check-pins.sh`: all 96 pins resolve. The only complaint is that
  Logisim isn't published yet.

### Reproducibility

| image | manifest | notes |
|---|---|---|
| `org.apache.pdfbox` 3.0.8 | `dcae2f4c` | same layers as the published `9d4222d3` |
| `com.github.reds.LogisimEvolution` 5.0.0 | `6de49650` | 52 MB layer |

PDFBox's vendor step made the same hash (`c542ae04`) in two runs from the
network. Logisim made the same image in two stores: `D:\zs\i32\p`, and
`D:\zs\i32b\p`, new and empty, where the SDK images came from ghcr.io and
the vendor step fetched everything again (7 min there, with the pulls; 2.5
min vendoring and 1.5 min building otherwise).

In CI, Logisim adds about 4 minutes to the published job (42 of 60 minutes
in the last run).

## Decisions made along the way

- **The test passes the circuit with `--file` only.** `--file` already
  hands the file to the app; given its path again, Logisim opened it twice,
  and closing the window left the second, so the run never ended.
- **The time zone**: replacing `new Date()` alone wasn't enough, as the
  text form is formatted in the JVM's zone (UTC on the runner, +07 here).
  Both are fixed strings now.

## Known gaps

- Logisim's FPGA commands need the vendors' tools from the host, which runs
  aren't granted ([gaps.md](gaps.md)).
- Still on OpenJDK 25.0.5 early access (below).

## For you

- **Now**, to make CI green again:
  1. Publish `pdfbox.json` (republish) and `logisim-evolution.json` (new):
     `scripts/publish.sh recipes/pdfbox.json recipes/logisim-evolution.json`.
     It pushes the catalog and runs the pin check last.
  2. Make the `com.github.reds.logisimevolution` package public.
  3. Commit and push; then I check both CI jobs.
- **v0.31.0** (iteration 31's zigsaw) can be tagged any time; it doesn't
  depend on the images.
- **When Temurin releases 25.0.5** (OpenJDK's was due 2026-10-20; Temurin's
  API still listed 25.0.4.1 on 2026-10-19), ask me to re-pin:
  - the JDK and JRE recipes move to the release's zips;
  - all seven Java images are rebuilt in order and checked in two stores:
    JDK, JRE, Maven, Gradle, PDFBox, PlantUML, Logisim;
  - then you republish the seven.

## Suggested for iteration 33

- The Temurin 25.0.5 re-pin above, if not done separately.
- A JavaFX app (OpenJFX from Maven Central).
- `jlink` runtimes made for each Java app.
- ZLS from source, with a vendor step for zig's package manager.
