# Iteration 55: toolchains on soft, and the low default's red rows

Built 2026-10-28. zigsaw 0.54.0, unchanged (only a unit test changed). To
publish: the 15 toolchains' images (new configs, the same layers) and TeX
Live (a new layer), before the push.

## Outcome

- **Toolchains' images ask for soft.** Windows starts a program whose file
  is labelled low at low integrity, whoever starts it, and what a
  low-integrity program writes is labelled low. Under iteration 54's
  default, `zig build`, `cargo install`, `npm install` or `pip install` in a
  project made programs there that ran at low outside zigsaw too, and
  CI's own zigsaw.exe started at low after a zig run in the repository.
  zig, Rust, cargo-c, Go, CMake, make, Meson, Node, Python, the JDK, Maven,
  Gradle, and the GTK, Qt and PHP SDKs now ask for `soft`, as Kanboard's
  does; other apps stay low.
- **TeX Live makes its formats at low as an administrator**, as GitHub's
  runners are: its Perl opened HKLM for writing when it saw an
  administrator, which a low-integrity run can't.
- **Iteration 54's run, fixed** (below), but for Kanboard's page, which CI
  served without a login form and which nothing here reproduces: the smoke
  row now keeps it.

## Starting decisions

From the planning session (plan file `plan-iteration-55-rosy-lobster.md`):

- **Toolchains ask for soft** in their images (your pick, over zigsaw
  choosing soft for every app with a writable `cwd`, keeping low with a
  warning, or a read-only `cwd` at low).
- **Fixes only**, no feature (your pick).
- **An elevated reproduction here** for what failed only on CI (your pick,
  over a diagnostic CI branch, or diagnostics only): one UAC prompt.
- Mine:
  - The SDK bases (GTK's, Qt's) stay as they are: they export nothing, so
    nothing runs them.
  - Recipes that pin a toolchain as a runtime (the GTK, Qt and PHP SDKs and
    ZLS pin zig; Prettier and the PHP SDK Node; PostgreSQL Python; Maven,
    Gradle and Scene Builder the JDK) keep their pins: only an app's own
    image decides its sandbox (`override.sandboxOf` reads the app's
    config), and the same layers deploy once. check-pins.sh warns only when
    a pin's layers differ.
  - 7-Zip and MinGit, which can write programs too, stay low: a gap.

## What was built

### Slice 0: why CI was red

Iteration 54's push run (40656264103) reproduced every published group, and
Kanboard's and Xdebug's images were on ghcr.io. It was red in six places:

- **Unit tests**: a root on the runner has a key algorithm zig's std
  doesn't know (`CertificateHasUnrecognizedObjectId`). zig's own bundle
  skips such a root (`std/crypto/Certificate/Bundle.zig`); the test failed
  on it.
- **build.sh's zig group** (25 rows): `zig run … env` ran from the
  repository, at low, and labelled it, `zig-out\bin\zigsaw.exe` with it.
  Every later zigsaw started at low integrity and the store refused it
  (`AccessDenied`, or nothing). Reproduced here: a copy of zigsaw in a
  folder an app with `cwd` ran in at low got `Low Mandatory Level:(I)`, and
  its next command failed with `AccessDenied`.
- **build.sh's langs group** (every row after `cargo install`): the same.
  The row runs the installed program's shim after its `cd` subshell ends,
  so from the repository: Rust's image has `cwd`, and the run labelled the
  repository.
- **texlive.sh** (11 rows): no format at low. Reproduced here only from an
  elevated shell: mktexfmt's Perl stops at `TLWinGoo.pm` line 307, `Can't
  use an undefined value as a HASH reference`. TLWinGoo asks
  `Win32::IsAdminUser()`, which is true for an administrator's token at low
  integrity too, and then opens HKLM's environment for writing, which a
  low-integrity process can't. Here, unelevated, it isn't an administrator,
  and the suite's data directory already had formats from soft runs.
- **certs.sh**, Composer in an AppContainer on Server 2025 (empty output,
  as in iteration 53's run): Composer starts its subprocesses through
  Symfony's Process, whose pipes on Windows open `NUL`, which an
  AppContainer there can't (tests/acprobe.zig's `nul`), as MinGit's git.
- **Kanboard's smoke row**: the server answered 200 without a login form.
  A fresh pull store here serves the form, with or without PHP's seven
  extensions, elevated or not.

### Slice 1: the tests

- [src/roots.zig](../src/roots.zig)'s test skips the roots zig's std
  doesn't know, as its bundle does.
- [tests/build.sh](../tests/build.sh) runs from its work directory, and
  checks at the end that no run labelled the repository, as the other
  suites do. PHP's extension-point row compares what PHP prints, not
  zigsaw's notes with it.
- [tests/texlive.sh](../tests/texlive.sh) starts from an empty data
  directory (one the store has is set aside, and put back), so first use is
  what's checked each time.
- [tests/certs.sh](../tests/certs.sh): Composer's AppContainer row is a
  known gap where the probe can't open `NUL`, and a failure prints
  Composer's error, not only curl's.
- [tests/published.sh](../tests/published.sh): a server's smoke row that
  gets no login page keeps the page with the logs (`<id>.page.html`) and
  prints its title.

### Slice 2: toolchains ask for soft

- `"sandbox": "soft"` in the permissions of zig, Rust, cargo-c, Go, CMake,
  make, Meson, Node, Python, the JDK, Maven, Gradle, and the GTK, Qt and
  PHP SDKs (and the .NET SDK, unpublished).
- build.sh: zig's image runs under soft unless told otherwise, and labels
  nothing. Its two PHP rows that compared everything a run printed compare
  what PHP prints: with the SDK under soft, PHP's run is the first to label
  their directory, and zigsaw says so on stderr.
- The .NET SDK's new config gives it a new manifest (`7687b4c6`), which the
  .NET runtime (an image source), Files and Pinta now pin: none is
  published, so a fresh store has only what it builds. The runtime's layer
  is the same (`c6a71371`), and so its new manifest (`a9e05a1f`) is pinned
  by Files and Pinta.
- [scripts/check-pins.sh](../scripts/check-pins.sh) warns about an older
  runtime pin only when its layers differ from the tag's.
- README, [recipes](recipes.md) and [gaps](gaps.md) say why.

### TeX Live

[recipes/texlive/texlive.json.in](../recipes/texlive/texlive.json.in) (and
the recipe it makes): TLWinGoo counts an administrator as one only when it
can open HKLM's environment for writing.

## Results

| check | result | time |
|---|---|---|
| the 15 toolchains in a fresh store `D:\zs\i55\p`, with zigsaw 0.54.0 (`D:\zs\i55\bin`) | each layer the published one, a new manifest only (table below) | 55 min, the Qt SDK 25 and the GTK SDK 18 of it |
| TeX Live, the same store | a new own layer `34dd87f6` (was `b41c89ee`), manifest `f0cd47c2`; Perl's and Ghostscript's layers the same | 7.5 min |
| unit tests | 132 passed | |
| `GROUP=base`, `zig`, `langs` tests/build.sh, from a scratch directory | 92, 36, 53 ok; 0 failed | 1, 5, 8.5 min |
| tests/texlive.sh (`D:\zs\i55\p`), from an empty data directory | 0 failed, 1 known gap (pdfLaTeX in an AppContainer) | 6 min |
| tests/certs.sh (`D:\zs\i53\p`), before the CA is trusted | 16 ok | 32 s |
| scripts/check-pins.sh | 74 recipes, 162 pins: 0 missing, 0 older runtimes | 97 s |
| the repository's ACL after all of it, and zigsaw.exe's | no label, no AppContainer entry | |

| image | manifest |
|---|---|
| org.ziglang.zig 0.16.0 | `f8310e4e` |
| org.gnu.make 4.4.1 | `9130adc7` |
| com.mesonbuild.meson 1.12.1 | `a54665ed` |
| org.cmake.cmake 4.4.4 | `6954eda9` |
| org.nodejs.node 24.21.0 | `59b7c3f8` |
| org.python.python 3.14.7 | `107bb4da` |
| org.golang.go 1.27.1 | `f76f58bb` |
| org.rust-lang.rust 1.99.0 | `fd8d6b5a` |
| org.openjdk.java.Sdk 25.0.5_8 | `5af95a49` |
| org.apache.maven 3.10.0 | `49c7453c` |
| org.gradle.gradle 9.8.1 | `64fb0814` |
| net.php.php.Sdk 8.5.11 | `559f22ff` |
| com.github.lu-zero.cargo-c 0.10.25 | `b2c9925e` |
| org.gtk.Gtk4.Sdk 4.24.1 | `ce940862` |
| io.qt.Qt6.Sdk 6.12.0 | `80bea4fd` |

Not run again: the suites whose apps and images didn't change (sandbox.sh,
the GTK, Qt, Java, PHP and PostgreSQL suites, matrix.sh), and nothing
elevated after the fix: the second UAC prompt was declined. TeX Live's
fix is checked on CI, whose runners are elevated.

## Known gaps

New in [gaps](gaps.md):

- a program labelled low starts at low integrity: 7-Zip extracting
  programs, or MinGit checking them out, at low makes programs that start
  at low outside zigsaw too, until `zigsaw rm`.

No longer gaps: `zig fetch` under zig's default sandbox.

## Next

- **Publish** from the store `D:\zs\i55\p`, which has all 16, with
  `ZIGSAW=D:\zs\i55\bin\zigsaw.exe` (0.54.0), **before pushing**: CI's
  groups compare each recipe with the image at its version tag.
  - zig, make, meson, cmake, node, python, go, rust, java-sdk, maven,
    gradle, php-sdk, cargo-c, gtk4-sdk, qt6-sdk (new configs; their
    layers are on ghcr.io already, so each push is a config and a manifest);
  - texlive (a new layer, 236 MB).
- Then commit and push, and tag v0.54.0: zigsaw's binary didn't change.
- Then I read the run:
  - build.sh's zig and langs groups, and the base group's unit tests;
  - texlive.sh at low on an elevated runner;
  - certs.sh's Composer row in an AppContainer (a gap there now, with its
    reason printed);
  - Kanboard's smoke row: if it fails again, `org.kanboard.Kanboard.page.html`
    in the apps group's logs says what it served.
