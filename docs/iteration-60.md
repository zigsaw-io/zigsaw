# Iteration 60: iteration 59's red rows, and the small chains on zig 0.17

Built 2026-10-30. zigsaw **0.60.0**. Sixteen images to publish: Meson,
make, cargo-c, Ghostscript and TeX Live, and PHP's SDK, PHP, its seven
extensions, Composer and Kanboard.

## Outcome

- **Iteration 59's run goes green again.** Its suites job had three red
  rows from two causes, both iteration 59's: an app's first soft run printed
  an `error:` line about its data folder's label, and sandbox.sh expected
  medium where CI's elevated runners give high.
- **Meson, make, cargo-c, Ghostscript and PHP's SDK build on zig 0.17.0**,
  and what's built with them follows: TeX Live on the new Ghostscript, and
  PHP's extensions with the SDK's zig. The extensions needed one flag, for
  Xdebug: Clang 22 makes passing a pointer to another type an error.
- **GDAL's and PostgreSQL's chains stay on zig 0.16**: a link with zig 0.17
  commits twice the memory, and their builds' parallel links ran this
  machine out of it, three times. GTK's, Qt's and gettext's stay too, as
  planned.

## Starting decisions

From the planning session (plan file `plan-iteration-60-logical-lake.md`):

- **CI's fixes, plus the small chains on zig 0.17** (your pick, over fixes
  only, every chain including GTK's and Qt's, or a `registry-logins`
  permission): make, Meson, cargo-c, Ghostscript, PHP's SDK, PostgreSQL's
  SDK and GDAL's SDK, and what pins them.
- **PHP's image moves to the new SDK too** (your call), and Composer and
  Kanboard with it if its digest changes (it does).
- v0.59.0 was never tagged, so the release is 0.60.0.

Decided during:

- **GDAL and PostgreSQL stay on 0.16** (your pick, over limiting their
  builds to 8 jobs, or a bigger paging file), after GDAL's SDK failed with
  the memory you freed and a paging file. Their eight recipes are as they
  were.
- **php-ext lets incompatible pointer types through, as MSVC does** (mine,
  following the undeclared-function flag it already passes).

## What was built

### Slice 0: CI's fixes (0.60.0)

Iteration 59's push run (40929093476): every build and published group
green, so ZLS, SQLite, zstd, bat and ripgrep reproduce on Server 2025; the
suites job red in three rows.

- [src/run.zig](../src/run.zig)'s `unlabelData` returns before reading the
  data folder's label when the folder isn't there yet, an app's first run.
  Reading it printed `error: reading the integrity label of …: error 2
  (FILE_NOT_FOUND)` before the error was dropped, on every app's first soft
  run; certs.sh's zig row, which reports zig's first `error:` line since
  iteration 59, read that one.
- [tests/sandbox.sh](../tests/sandbox.sh)'s two data-folder rows take
  `medium` or `high`: with the label off, a program starts at the level of
  what started zigsaw, which on CI's elevated runners is high. A new row:
  an app's first soft run says nothing of its data folder (0.59.0 fails it).

### Slice 1: the chains on zig 0.17.0

Each chain's recipe pins zig 0.17.0's image (`93ec2b6b`) instead of
0.16.0's: [meson](../recipes/meson.json), [make](../recipes/make.json),
[cargo-c](../recipes/cargo-c.json), [ghostscript](../recipes/ghostscript.json)
as their SDK, [php-sdk](../recipes/php-sdk.json) as its runtime. Built in
pin order in store `D:\zs\i60\p`, each step re-pinning what pins it.

Facts in [findings](findings.md#the-small-chains-on-zig-017-iteration-60):

- GDAL's SDK failed three times 7 minutes in, where its link phase starts
  ("The paging file is too small"), and PostgreSQL's SDK in its links
  (`LLVM ERROR: out of memory`). A link with zig 0.17's `cc` commits 906 MB
  where 0.16's committed 425 MB, whatever is linked; a compile costs the
  same. Ninja's 18 jobs here need about 16 GB at the links; CI's 6 don't.
- zig 0.17's compiler-rt still has no `__cpu_model`: GDAL's CPUID patch
  would stay.
- Xdebug 3.5.3 passes `int *` for `DWORD *`, now an error in Clang 22.
  [php-ext](../recipes/php-sdk/php-ext.php) passes
  `-Wno-error=incompatible-pointer-types` with
  `-Wno-error=implicit-function-declaration`, MSVC's warnings both (C4133,
  C4013). The other extensions built without it.

### Slice 2: what pins them

- [texlive](../recipes/texlive.json): the new Ghostscript.
- [php](../recipes/php.json), [APCu](../recipes/php-apcu.json),
  [Xdebug](../recipes/php-xdebug.json), [igbinary](../recipes/php-igbinary.json),
  [redis](../recipes/php-redis.json) (and its igbinary),
  [ssh2](../recipes/php-ssh2.json), [yaml](../recipes/php-yaml.json),
  [zstd](../recipes/php-zstd.json): the new PHP SDK. PHP's layer is the one
  published (`a48cecfd`); its config names the new SDK, so its digest
  changes, and [Composer](../recipes/composer.json) and
  [Kanboard](../recipes/kanboard.json) pin the new one.
- Meson, make and cargo-c move alone: what pins them (GTK's SDKs,
  PostgreSQL's and GDAL's chains) keeps the 0.16-built images, still on
  ghcr.io by digest.

## Results

| check | result | time |
|---|---|---|
| the 16 in store `p`, then `p2` | the same manifests in both: Meson `7448a74d`, make `9add04a4`, cargo-c `fdfca547`, Ghostscript `deaacbe9`, TeX Live `7cc33783`, PHP SDK `095dc2d7`, PHP `36ad8bf0`, APCu `c20fcbfa`, Xdebug `449380a3`, igbinary `55396a61`, redis `64b307e2`, ssh2 `6f7d9699`, yaml `13f2dd18`, zstd `2ae97831`, Composer `efa6252d`, Kanboard `d9f2354c` | 2.5, 0.3, 7.7, 11.6, 6.9 min; PHP's under 1 min each |
| `zig build test` | passed | |
| tests/sandbox.sh | 0 failed (1 new row; 0.59.0 fails it) | 28 s |
| tests/certs.sh, untrusted rows, fresh store with Python and zig | 0 failed, zig's row ok | 94 s |
| tests/php.sh (store `p`) | 0 failed, 46 ok: Xdebug's own suites and step debugger, Kanboard | |
| tests/texlive.sh (store `p`) | 0 failed, 1 known gap | |
| tests/self.sh with 0.60.0 | 0 failed | 9.5 min |
| Defender scan of the 0.60.0 programs | no threats | |
| scripts/check-pins.sh | 13 missing, all pins of the 16 | |

## Next

- Publish **before pushing** (CI's apps and texlive groups compare them,
  its suites pull them), from store `D:\zs\i60\p` with
  `ZIGSAW=D:\zs\i60\bin\zigsaw.exe` (0.60.0), runtimes first:
  `scripts/publish.sh meson.json make.json cargo-c.json ghostscript.json texlive.json php-sdk.json php.json php-apcu.json php-xdebug.json php-igbinary.json php-redis.json php-ssh2.json php-yaml.json php-zstd.json composer.json kanboard.json`.
- Then commit and push, and I read the run. Meson's and cargo-c's recipes
  changed, so it checks GTK's groups and suites too (scripts/ci-groups.sh),
  which still build on the 0.16-built images they pin; TeX Live's group
  runs too.
- Then tag **v0.60.0**, and I read the Release run.
- Later: GDAL's and PostgreSQL's chains on zig 0.17, with fewer jobs or more
  memory here, or zig's link memory back down; then gettext, GTK and Qt.
