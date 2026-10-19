# Iteration 31: Java

Built 2026-10-19; to be published once OpenJDK 25.0.5 is released (see
"For you").

## Outcome

- **Java runs and builds in zigsaw**, in all three sandboxes. OpenJDK 25 is
  two images from Eclipse Temurin's builds: the JDK
  (`org.openjdk.java.Sdk`) and the JRE (`org.openjdk.java`), which Java apps
  run on. Java's `user.home` comes from Windows rather than the
  environment, so both images point it into the app's data.
- **Maven and Gradle** are images on the JDK's, and recipes pin a Java
  project's dependencies with a vendor step, then build offline:
  - Maven: the build itself fills the local repository, less the files
    that record when and from where.
  - Gradle: what it downloaded becomes a Maven repository (`gradle-vendor`),
    which an init script in Gradle's image serves to every repository a
    build declares.
- **Two Java apps** are built from source, for publishing:
  - **Apache PDFBox** 3.0.8, with Maven: a PDF toolkit and its debugger,
    which Explorer offers for `.pdf` files.
  - **PlantUML** 1.2026.9, with Gradle: diagrams from text, with the
    Graphviz its jar carries.

  Both keep their settings with the app, in every sandbox.
- **zigsaw 0.31.0** fixes two bugs in keeping registry keys, which Java's
  preferences found:
  - Taking a key back deleted the user's empty keys above it.
  - An AppContainer couldn't open the keys above its own.

## Starting decisions

From the planning session (plan:
`C:\Users\Test\.claude\plans\let-s-plan-to-add-tranquil-lollipop.md`):

- Your picks:
  - **Maven and Gradle** (Gradle depending on a probe), with **PDFBox and
    PlantUML** as the apps.
  - **`JAVA_TOOL_OPTIONS`** for `user.home`, in both images, over arguments
    in each command.
  - The ids **`org.openjdk.java.Sdk`** and **`org.openjdk.java`**.
- Mine:
  - Temurin's builds, not OpenJDK from source (which needs MSVC and
    Cygwin).
  - The JRE from Temurin's own zip rather than made from the JDK.
  - The ids `org.apache.maven`, `org.gradle.gradle`, `org.apache.pdfbox` and
    `com.plantuml.PlantUML`.
  - A Graphviz image for PlantUML, later dropped (see below).
  - No zigsaw change expected.

## What was built

### Java's images

- [`recipes/java-sdk.json`](../recipes/java-sdk.json) is Temurin's JDK zip,
  without `lib/src.zip`. It exports `java`, `javaw`, `javac`, `jar`,
  `jshell`, `javadoc`, `jdeps`, `jlink` and `keytool`, and its `bin` is
  builds' PATH.
- [`recipes/java.json`](../recipes/java.json) is Temurin's JRE zip.
- Both set `JAVA_HOME` and
  `JAVA_TOOL_OPTIONS="-Duser.home=${data}\home" -Dsun.font.layout.ffm=false`.
  The second option keeps JDK 25's text shaping out of what fails in an
  AppContainer ([findings](findings.md#java)).

### Maven and Gradle

[`recipes/maven.json`](../recipes/maven.json) (3.10.0, from Maven Central)
and [`recipes/gradle.json`](../recipes/gradle.json) (9.8.1) run on the JDK's
image, and start Java themselves, as `mvn.cmd` and `gradle.bat` would, so
that their aliases work in builds:

- Maven is given `-Dmaven.multiModuleProjectDirectory=.`, without which
  Maven 3 won't start.
- Gradle is given `-Dorg.gradle.daemon=false`: a run's job would end a
  daemon anyway.

Gradle's image also has two files of zigsaw's, from
[`recipes/gradle/`](../recipes/gradle/):

- `init.d/zigsaw-offline.gradle`: with `ZIGSAW_GRADLE_REPO` set, every Maven
  repository any part of a build declares is that directory.
- `zigsaw/GradleVendor.java`, run as `gradle-vendor`: it turns a Gradle
  home's downloads into a Maven repository.

The vendor steps are described in recipes.md
([Maven](recipes.md#maven), [Gradle](recipes.md#gradle)).
[`.gitattributes`](../.gitattributes) keeps `recipes/gradle/` LF on every
checkout, as the image carries the files byte for byte.

### The apps

- [`recipes/pdfbox.json`](../recipes/pdfbox.json):
  - built from PDFBox's source release on Maven Central (`-pl :pdfbox-app
    -am package -DskipTests`);
  - `pdfbox` and `pdfbox-debugger` (with `javaw`, a shortcut, `.pdf`);
  - keeps `Software\JavaSoft\Prefs\org\apache\pdfbox`.
- [`recipes/plantuml.json`](../recipes/plantuml.json):
  - from the GitHub tag (`-Pfast jar -x generateGitProperties`), with
    `CompilationInfo.java` filled with the version, commit `18d0aae` and
    its time;
  - `plantuml` and `plantuml-gui` (a shortcut);
  - keeps `Software\JavaSoft\Prefs\net\sourceforge\plantuml`.

### zigsaw

[`src/hkcu.zig`](../src/hkcu.zig) and [`src/acl.zig`](../src/acl.zig):

- **Only the keys a run made are deleted.** Putting a key in place records
  the outermost key above it that it made (`Made` in its record), and taking
  it back deletes empty keys up to that one, no further. Records of older
  zigsaws have none, and delete none.
- **AppContainer runs may read the keys above the kept ones.** Each existing
  key between `Software` and a kept key is granted read access for the
  app's capability, that key only. Taking the key back revokes it: the SID
  from the app's id, the keys from the key's path, so a run that didn't end
  is settled too.

Version 0.31.0.

### Tests

- [`tests/build.sh`](../tests/build.sh), Java's section (17 checks):
  - the images;
  - the JDK as an app, with `user.home` in its data, in each sandbox;
  - a Swing fixture laying out text ([`tests/build/swing`](../tests/build/swing));
  - a Maven and a Gradle fixture ([`tests/build/maven`](../tests/build/maven),
    [`tests/build/gradle`](../tests/build/gradle), the latter with a plugin
    from the plugin portal), each run in every sandbox and rebuilt to the
    same image.
- [`tests/java.sh`](../tests/java.sh), new, local (27 checks, 30 s with the
  apps built):
  - PDFBox's round trip and rendering, and its debugger opening a file given
    with `--file`;
  - PlantUML's diagrams and its window;
  - all of those in each sandbox, and their shims, shortcuts and `.pdf`
    registration;
  - that HKCU keeps neither app's key between runs, and the user's `Prefs`,
    which no AppContainer may read afterwards;
  - that no run labelled or granted the repository.
- [`tests/sandbox.sh`](../tests/sandbox.sh): an app keeping a key two levels
  below an empty key that was there. It fails on 0.26.0.
- [`tests/matrix.sh`](../tests/matrix.sh): PDFBox and PlantUML rows, and
  fake user folders (`ZIGSAW_USER_FOLDERS`): the two apps are its first that
  declare Desktop, Documents and Downloads, which its low and AppContainer
  rows would otherwise label and grant, yours or the CI runner's.
- [`tests/published.sh`](../tests/published.sh): PDFBox's smoke run is
  `version`.

## Results

### Tests

- Unit tests: 104 of 104 (one new: keys above a key).
- [`tests/sandbox.sh`](../tests/sandbox.sh): all, the new row included,
  which fails on zigsaw 0.26.0 ("the key that was there went").
- [`tests/build.sh`](../tests/build.sh), Java's section alone: 17 of 17 in
  78 s, seeded with the downloads and the vendor steps' results.
- [`tests/java.sh`](../tests/java.sh): 27 of 27 in 30 s, against both
  stores. By hand: while an AppContainer run was open, its capability could
  read `Prefs`; after it, nothing could.
- [`tests/matrix.sh`](../tests/matrix.sh): all as intended, the new rows
  ok in every sandbox (and PDFBox refused an ungranted file in an
  AppContainer); 95 s of checks. PDFBox exits 0 when it can't read its
  input, so that row checks for the PDF.
- `scripts/check-pins.sh` against ghcr.io: 12 missing, the six new images
  and the six pins among them, until they're published; no other.
- Not run again: the other suites, and `tests/build.sh` whole. zigsaw's
  change is in keeping registry keys, which sandbox.sh and java.sh cover;
  build.sh only gained its Java section.

### Reproducibility

Built in a probe store, then in `D:\zs\a`, seeded with the downloads but not
the vendor steps' results (Maven and Gradle fetched everything again), with
the same digests. The Maven, Gradle and Swing fixtures also matched in two
stores.

| image | manifest | own layer (compressed) | build (second store) |
|---|---|---|---|
| `org.openjdk.java.Sdk` 25.0.5_7-ea | `e45ed698` | 84 MB | 12 s |
| `org.openjdk.java` 25.0.5_7-ea | `4d05838b` | 55 MB | 9 s |
| `org.apache.maven` 3.10.0 | `c5d44d38` | 9.6 MB | 1 s |
| `org.gradle.gradle` 9.8.1 | `3e65c987` | 144 MB | 11 s |
| `org.apache.pdfbox` 3.0.8 | `9d4222d3` | 12 MB | 235 s, its vendor step included |
| `com.plantuml.PlantUML` 1.2026.9 | `e10cf95a` | 27 MB | 342 s, its vendor step included |

These are on the early-access JDK; the release's images will have other
digests (see "For you").

In CI, the published job (29 minutes in the last run) gets the six to
build, about 10 minutes more, and the build job (21) Java's section of
build.sh, about 5; both have 60.

## Decisions made along the way

- **OpenJDK 25.0.5, not 25.0.4.1.** The release of the day can't load its
  security settings in an AppContainer (JDK-8352728). The recipes were
  developed on Temurin's early-access build of 25.0.5, which can, until its
  release, due 2026-10-20.
- **`sun.font.layout.ffm=false` in both images** (my call): JDK 25's
  HarfBuzz binding fails in an AppContainer in 25.0.5 too. The JNI binding
  is the same HarfBuzz, so soft and low lose nothing.
- **No Graphviz image**: PlantUML's jar has its own `dot`, which worked in
  every sandbox.
- **Gradle 9.8.1 for PlantUML**, whose wrapper names 9.3.1: it built
  without changes.
- **Maven and PDFBox from Maven Central**: archive.apache.org and
  downloads.apache.org didn't answer from here, and Central keeps every
  release.
- **Fixing zigsaw's registry keeping** (my call; that's why there's a
  release): the first bug deleted keys of yours, and Java's preferences in
  an AppContainer needed the second.
- **Gradle's repositories rewritten, not replaced**: `configureEach` sets
  each Maven repository's URL whenever a build declares it, which catches
  those declared after the init script runs.

## Known gaps

See [gaps.md](gaps.md):

- every Java program prints `Picked up JAVA_TOOL_OPTIONS`;
- in an AppContainer, `toRealPath` fails, and `jps`/`jcmd` can't see the
  program;
- `mvn` doesn't read `.mvn/jvm.config` or `MAVEN_OPTS`;
- version ranges and SNAPSHOTs can't be vendored;
- an AppContainer may read the names of other Java apps' preferences keys
  while it runs;
- no JavaFX, no OpenJDK from source.

## For you

- **Don't publish yet.** The JDK and JRE recipes point at Temurin's
  early-access 25.0.5+7, as 25.0.4.1 can't run Java's security code in an
  AppContainer. Once Temurin releases 25.0.5 (OpenJDK's is due
  2026-10-20), the two recipes move to its zips, everything is rebuilt and
  re-pinned in order, and checked in two stores again. Ask me to do that
  then; `D:\zs\i32\repin.sh` and `repro.sh` do most of it.
- Then publish the six (`scripts/publish.sh` with them, in this order; it
  pushes the catalog and runs the pin check last): `java-sdk.json`,
  `java.json`, `maven.json`, `gradle.json`, `pdfbox.json`,
  `plantuml.json`. Make the six packages public.
- Then commit, push, and tag `v0.31.0`, as zigsaw changed. Before the
  images are on ghcr.io, a push makes the Reproduce run's `pins` and
  `published` jobs fail on the six.
- Optionally, file the OpenJDK report drafted in
  `D:\zs\i32\upstream\openjdk-systemlookup-realpath.md`.

## Suggested for iteration 32

- An app with JavaFX (OpenJFX from Maven Central), or a bigger Gradle app
  (Logisim-evolution).
- Java apps' runtimes made for them with `jlink`, smaller than the JRE.
- ZLS from source, with a vendor step for zig's package manager.
