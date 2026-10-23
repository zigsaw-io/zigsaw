# Iteration 43: TeX Live, on Perl and a Ghostscript built with zig

Built 2026-10-23. No zigsaw change (still 0.42.0). Two new images to
publish: Ghostscript, then TeX Live.

## Outcome

- **The v0.42.0 Release run was red**: `tests/self.sh` checks that
  [`zigsaw.json`](../zigsaw.json) has build.zig.zon's version, and it had
  0.36.0, unchanged since iteration 36. It has 0.42.0 now. Release's first
  step, and a step of Reproduce's base job, compare the two, so a forgotten
  bump fails in seconds, and on a push before a tag.
- **[`org.tug.texlive`](../recipes/texlive.json) is TeX Live 2026's small
  scheme**: LaTeX with pdfTeX, XeTeX and LuaTeX, MetaPost, BibTeX, Biber,
  MakeIndex and latexmk. It has 430 packages from tlnet, each pinned by
  sha256, and TeX Live's own Windows programs, installed by TeX Live's
  installer at build time. Its layer is 236 MB.
- **Its Perl and Ghostscript are images of their own**, which it lists as
  runtimes:
  - Perl is the published Strawberry Perl (`org.perl.perl`).
  - Ghostscript is
    **[`com.artifex.Ghostscript`](../recipes/ghostscript.json) 10.08.0,
    built from source with zig**: one 13 MB program with its resources
    compiled in.
  - TeX Live's own Perl and Ghostscript are only used while it builds.
- **Both reproduce**: the same digests in three fresh stores, the last one
  downloading everything as a runner would.
- **Formats are made on first use**, in the app's data directory, as
  formats dumped at build time differ from build to build. That took four
  fixes to TeX Live's Windows scripts, so that the first run works.
- **Everything works in the soft and low sandboxes.** In an AppContainer no
  TeX Live program starts on this Windows (a known gap).

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\plan-to-build-texlive-mutable-sloth.md`):

- **scheme-small**, over basic, medium and full.
- **TeX Live 2026 from today's tlnet** (revision 80721), over 2025's frozen
  repository.
- **Prebuilt TeX Live programs, with the reusable parts as images of their
  own**: Ghostscript built from source, and the published Perl as a
  runtime. kpathsea, SyncTeX and dvipdfmx from source weren't picked.

Made with you along the way:

- **Formats on first use** (slice 1's gate: a file stays non-reproducible).
  The alternatives were making the engines' dumps deterministic, which is
  unbounded for LuaTeX, or shipping non-reproducible formats.

## What was built

### The release fix

- `zigsaw.json` 0.42.0.
- [`release.yml`](../.github/workflows/release.yml): "The tag is
  build.zig.zon's version, and zigsaw.json's".
- [`reproduce.yml`](../.github/workflows/reproduce.yml): "zigsaw.json has
  build.zig.zon's version", in the base build group.

### Pinning TeX Live

**[`scripts/texlive-pins.sh`](../scripts/texlive-pins.sh)** writes
`recipes/texlive.json` from
[`recipes/texlive/texlive.json.in`](../recipes/texlive/texlive.json.in),
and the installer's profile beside it. It:

- downloads tlnet's `texlive.tlpdb`;
- takes the scheme's packages for Windows: their closure, with each
  `.ARCH` dependency as `.windows`, plus the packages install-tl adds on
  Windows (tlperl, tlgs, and its required packages);
- downloads every archive and checks it against the database's sha512;
- writes each one's URL and sha256 as a `type: file` source in
  `repo/archive/`, with the database and `install-tl.zip`;
- sets the version to `2026.<repository revision>`;
- exports every `.exe` of the packages, less a deny list: tlmgr and its
  GUIs, the `-sys` scripts, `updmap`, `fmtutil`, `mktexlsr`/`texhash`,
  script runners, and documentation browsers.

It took 3 minutes cold. `MIRROR` defaults to MIT's CTAN mirror, `SCHEME`
to `scheme-small`, and `TEXLIVE_PINS_CACHE` keeps the downloads.

### The TeX Live image

The build runs install-tl offline with its own Perl, from the pinned
archives laid out as a repository. The profile makes it portable and
leaves out documentation, sources, `collection-wintools` and formats.
install-tl took 1m19s. Then:

- **fontconfig's configuration** for XeTeX names
  `<dir prefix="relative">../../../texmf-dist/fonts/...` and
  `WINDOWSFONTDIR`, not `B:/prefix/...` and the build machine's
  `C:/WINDOWS/fonts`. Before this, XeTeX found no font by name once
  deployed. Its cache goes to `XE_FC_CACHEDIR` in the data directory.
- **Dated header lines go** from `fmtutil.cnf`, `updmap.cfg`,
  `language.dat`, `language.def`, `language.dat.lua` and the profile copy.
  The package database names tlnet, not the build's repository.
- **`TLWinGoo.pm`** loads `Win32::Shortcut` in an `eval`. Strawberry Perl
  doesn't have it, and TeX Live uses it only for shortcuts.
- **`TLUtils.pm`**'s check of whether `TEXMFSYSVAR` is writable uses
  `dir_writable`, which writes a file, instead of Perl's `-w`, which on
  Windows reads only the read-only attribute.
- **`mktexfmt`** is fmtutil.pl under that name (`mktexfmt.pl` and a
  runscript stub). TeX Live's own `mktexfmt.exe` makes the format without
  telling kpathsea where it is, so the run that asked for it stopped.
- **`ls-R`** is made again for `texmf-var` and `texmf-dist`.
- **`cleanup`** removes tlperl, tlgs, the installer's files and the logs.

Runs keep `TEXMFVAR`, `TEXMFCONFIG` and `TEXMFHOME` in the data directory.
They have `TEXLIVE_WINDOWS_TRY_EXTERNAL_PERL=1`, so TeX Live's runscript
takes `perl.exe` from PATH (Perl's image), and `TEXLIVE_WINDOWS_EXTERNAL_GS`
names Ghostscript's image. The app's command is latexmk.

### Ghostscript

[`recipes/ghostscript.json`](../recipes/ghostscript.json) is the release
tarball with its bundled libraries, configured for MinGW and built with zig
and BusyBox's make. Four things it needed, each found on a 10-minute
rebuild:

- `ac_cv_prog_MAKE_EXISTS=yes`: configure looks for a `make` file on PATH,
  and BusyBox's is an applet.
- `LD`: the [autotools ld](../recipes/gtk4-sdk/autotools-ld.sh), for
  libtiff's configure.
- The makefile gets an empty `MAKEDIRS` and runs `make directories` first.
  configure decides BusyBox's make isn't GNU make, yet writes GNU's
  order-only `| directories`.
- `-Wp,-w` → `-w`, and `mkromfs.c`'s stand-in for the Windows
  `gp_stat_impl` is kept to MSVC: MinGW builds use the Unix one.

It exports `gs` and `gswin64c`, but not `ps2pdf`, which TeX Live exports
(a script that uses this Ghostscript).

### Tests, CI and docs

- **[`tests/texlive.sh`](../tests/texlive.sh)**, 21 checks in 90 s from an
  empty data directory. Fixtures are in `tests/texlive/`. It checks:
  - pdfLaTeX, XeLaTeX and LuaLaTeX with Latin Modern found by name, each
    making its format in the data directory;
  - fontconfig's and luaotfload's caches there;
  - kpathsea's trees;
  - BibTeX, MakeIndex, Biber, MetaPost and latexmk;
  - epstopdf, and `latex` → `dvips` → `ps2pdf`;
  - the same PDF twice with `SOURCE_DATE_EPOCH`;
  - nothing written in the deployment, which has no formats;
  - pdfLaTeX and LuaLaTeX at low integrity;
  - pdfLaTeX in an AppContainer, gated on the probe.
- **[`tests/acprobe.zig`](../tests/acprobe.zig)** has a new check,
  `self-long-name` (`GetLongPathNameW` of its own path).
- **CI**:
  - group `texlive` (Ghostscript, TeX Live), with a 75-minute timeout;
  - [`scripts/ci-groups.sh`](../scripts/ci-groups.sh) builds it only when
    its recipes, the pin script or the shared check files change, and
    weekly;
  - the suites job pulls `texlive` and runs `tests/texlive.sh`.
- **Docs**:
  - recipes.md: "TeX Live" and "Ghostscript".
  - findings.md: TeX Live and Ghostscript.
  - gaps.md: the AppContainer gap, formats on first use, sequential
    downloads and no tlmgr.
  - published-apps.md and the README's suite list.

## Results

| check | result | time |
|---|---|---|
| unit tests | 111 passed | |
| Ghostscript in stores g, gs2 and published.sh's | `bc9081d9` in all three; layer `ce9c2b06`, 13 MB | 12m51s–15m46s |
| TeX Live in stores g, gs2 and published.sh's | `636af1ea` in all three; layer `b41c89ee`, 236 MB | 6m42s seeded, 14m33s downloading |
| the previous recipe (no mktexfmt fix) in p3, p4 | `f9d18543` in both | |
| `GROUP=texlive tests/published.sh` | 0 failed, 2 not published yet | 27 min |
| `tests/texlive.sh` (store g) | 21 ok, 1 known gap | 90 s |
| `--version` of both, as published.sh's smoke run | latexmk 4.88, gs 10.08.0 | |
| `scripts/check-pins.sh` | only the two new images and TeX Live's pin of Ghostscript missing | |
| `scripts/ci-groups.sh` | lists `texlive` | |

Not run here: `tests/self.sh` (its one failing check is fixed, and Release
runs it), the matrix and the other suites. Nothing they cover changed, but
`tests/acprobe.zig` gained a line.

## Decisions made along the way

All mine, except formats on first use:

- **No formats in the image.** You chose this at the gate, after I measured
  where the differences were.
- **Patches as `sed`s with checks** in the recipe's build commands
  (TLWinGoo, TLUtils, fonts.conf, headers, mktexfmt), so a TeX Live update
  that changes them fails the build rather than slipping through.
- **The AppContainer row is a known gap, gated on `self-long-name`.** zigsaw
  can't grant a drive root's listing without admin, and the programs are
  TeX Live's builds.
- **No `GS_LIB`** for TeX Live's Ghostscript: its resources are compiled
  in.
- **The texlive group runs only when its files change.** A fresh build
  downloads 432 files from a mirror that replaces them as packages change.

## Known gaps

- **AppContainer**: no TeX Live program starts where AppContainers can't
  list the drive root (gaps.md).
- **Each format is made on first use** (a few seconds), once per data
  directory; `--ephemeral` makes them on every run.
- **No tlmgr.** Packages change by re-pinning; your own go in `TEXMFHOME`.
- **A fresh build downloads its 432 files one after another**: 8 to 10 of
  its 15 minutes.
- **Before you publish, a fresh build depends on tlnet not having replaced
  a pinned archive since today.** After you publish, builds take them from
  the sources next to the image.

## For you

1. **Publish from `D:\zs\i43\g`**, which built both images and holds every
   pinned file. Use the zigsaw that built them, so nothing rebuilds:
   `ZIGSAW_HOME='D:\zs\i43\g' ZIGSAW='D:\zs\i43\bin\zigsaw.exe' bash scripts/publish.sh recipes/ghostscript.json recipes/texlive.json`.
   Pushing their sources matters for TeX Live, since tlnet moves. Then make
   both packages public; publish.sh ends with `scripts/check-pins.sh`.
2. **Commit and push**: `scripts/texlive-pins.sh` and `tests/texlive.sh`
   need the executable bit
   (`git update-index --chmod=+x scripts/texlive-pins.sh tests/texlive.sh`).
3. **Move the v0.42.0 tag** to the new commit (its release never
   published), so Release runs again.

Then I read the run: the texlive group's time on a runner, and
tests/texlive.sh in the suites job, whose probe on Server 2025 says whether
the AppContainer row is a gap there too.

## Candidates for iteration 44

- **Parallel downloads in zigsaw's fetcher** (TeX Live's 432 files, and any
  recipe with many sources).
- **Collections as extension images** joining TeX Live's runs through
  kpathsea's `TEXMFAUXTREES` (the extension point would need a
  comma-separated join).
- **scheme-medium** as a second image, or dvisvgm with Ghostscript's
  library (`gsdll64.dll`, not built yet).
- **Ghostscript's build in parallel**, as gettext's: 8 of its 13 minutes are
  one compile at a time.
- Upstream reports for TeX Live: Windows `mktexfmt.exe` doesn't print the
  format's path, `-w` in `setup_sys_user_mode`, `Win32::Shortcut` required
  on load, and absolute paths in fonts.conf.
- From before: install consent, the Temurin re-pin (Windows GA), unity
  builds for qttools and qtbase, parallel make for Gnumeric.
