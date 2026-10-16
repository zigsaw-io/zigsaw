# Iteration 24: extension points, and PHP extensions with PHP's libraries

Concluded 2026-10-16.

## Outcome

- **Extension points**, as a Flatpak runtime's extensions: an image can
  declare a point (`extensions`), and an image that `extends` it joins
  every run of whatever has the point, once installed, without apps listing
  it. Variables the point `join`s add up instead of replacing each other.
  `--noextension` leaves one out, for a run or as an override. zigsaw 0.24.0.
- **PHP's runtime has one**, so `zigsaw pull net.php.php.Xdebug` is enough
  for `php` and every app on PHP to load Xdebug, under the three sandboxes.
- **PHP extensions that need PHP's libraries build**: the SDK has the
  headers and import libraries of what PHP ships (OpenSSL, libssh2, zlib,
  libxml2, ICU...), from php.net's own packages, and `php-ext` finds them
  as PHP's configure would. New images: **ssh2** 1.5.0 (libssh2 and
  OpenSSL), **igbinary** 3.2.17RC1 and **PhpRedis** 6.3.0 with igbinary's
  serializer (an extension built with another); **Xdebug** now with
  compression (zlib). Each passes what its MSVC 14.44 build passes.
- **CI runs in two jobs side by side**: the published recipes with the
  suites that use their store, and `tests/build.sh` on its own.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-24-glittery-lovelace.md`):

- **Extension points** (your pick), with installed extensions joining
  **every run**, and an opt-out per app (your pick over opting in).
- **The SDK carries the libraries PHP itself carries** (your pick over the
  whole deps series), so extensions use the DLLs PHP loads.
- **Proofs: Xdebug with compression, ssh2, redis with igbinary** (your
  picks; redis on Windows links no library, so igbinary came with it, as an
  extension that needs another).
- **CI as two parallel jobs** (your pick over a longer timeout or a cache).
- Mine: the fields `extensions` and `extends` (no new config type: a zigsaw
  that doesn't know them installs extensions as apps, and nothing joins);
  PHP's point version is PHP's extension build id; test servers in Go
  (an SSH server on golang.org/x/crypto and pkg/sftp, miniredis), as the
  machine has none; parity with MSVC 14.44 builds as the bar.

## What was built

### Extension points

- [`src/extensions.zig`](../src/extensions.zig): a run's points (the app's,
  then those its runtimes have, which apps copy from them), the installed
  extensions of those points at their versions, in id order, each after
  those it `needs`, less those the app lists as runtimes and those left
  out. Each joins as a runtime the app didn't list: its PATH entries and
  variables after the runtimes', before the app's, its directory granted
  in an AppContainer. A run notes each installed extension that doesn't
  join and why (another version, a need missing).
- [`src/environment.zig`](../src/environment.zig): `join`, which adds a
  value's `;`-separated entries after a variable's, without repeats.
- `oci.zig`, `recipe.zig`, `deps.zig`: the fields, their checks (an
  extension can't have runtimes; `join` can't name PATH), copied into an
  app's runtimes.
- `override.zig`, `main.zig`: `--noextension=<id>` and `--extension=<id>`
  for `run` and `override`; saved overrides leave the lists out when
  empty, so 0.23 still reads them. `list`, `info` and `pull` show points
  and what extends them; `run -v` the extensions that joined.

### PHP's libraries

- [`recipes/php-sdk.json`](../recipes/php-sdk.json): fourteen of php.net's
  deps packages (the 8.5 series' versions) in `dev\deps`, headers and
  import libraries of PHP's DLLs, licences kept; their DLLs, tools, static
  libraries and debug files left out.
- [`config-w32.js`](../recipes/php-sdk/config-w32.js): `PHP_PHP_BUILD`,
  `CHECK_LIB` and `CHECK_HEADER_ADD_INCLUDE` looking there; libraries
  `php8.dll` has (zlib, libxml2, libiconv) found as `php8.lib`;
  configure's `SETUP_OPENSSL`, `SETUP_ZLIB_LIB`, `SETUP_SQLITE3`; `PHPDLL`;
  `PHP_INSTALL_HEADERS`; other extensions found by their `PHP_EXT_<EXT>`.
- [`php-ext.php`](../recipes/php-sdk/php-ext.php): the deps' headers on
  every compile, as configure has them; an extension's import library and
  installed headers in its output; undeclared calls a warning, as MSVC's.
- Images: [`php.json`](../recipes/php.json) declares the point;
  [`php-apcu.json`](../recipes/php-apcu.json),
  [`php-xdebug.json`](../recipes/php-xdebug.json) extend it; new
  [`php-igbinary.json`](../recipes/php-igbinary.json),
  [`php-redis.json`](../recipes/php-redis.json) (igbinary's image as an
  SDK, `needs` it), [`php-ssh2.json`](../recipes/php-ssh2.json).

### CI

[`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml): job
`published` (published.sh, then store, shims, sandbox, batch, ctrlc,
install, registry and matrix in its store) and job `build` (unit tests,
then build.sh, which downloads what it builds from), each with its logs.

### Tests

- Unit tests for the fields' checks, joining, choosing extensions and
  overrides.
- [`tests/build.sh`](../tests/build.sh): an extension points section
  (BusyBox: order and needs, another version left out with a note, an
  app's own entry last, `--noextension` and overrides, an app listing an
  extension, low and AppContainer, removing one, an extension with
  runtimes refused); the PHP section's test extension calls zlib, libxml2
  and OpenSSL, and joins PHP's runs installed.
- [`tests/php.sh`](../tests/php.sh): the five extensions joining PHP's
  runs in each sandbox, `--noextension` and `needs`, the import libraries
  and headers in their images, the igbinary, ssh2 and redis suites (the
  last two against [`tests/php/servers`](../tests/php/servers)), the
  consumer app with the installed ones too.

## Results

### Tests

- Unit tests: 98 (90 + 8).
- `tests/build.sh`: 142 of 142, 17.5 min with `SEED_DOWNLOADS`; its
  extension points section alone 14 of 14, its PHP section 8 of 8 in a
  fresh store. Unseeded, as CI's `build` job runs it (at iteration 23's
  code): 127 of 127 in 21 min.
- `tests/php.sh`: 29 of 29, 4 min.
- `sandbox.sh`, `shims.sh`, `store.sh`, `batch.sh`, `ctrlc.sh`,
  `install.sh`: all pass. The matrix: as intended (once three BusyBox
  shells my probes had left were gone; its "job ends background children"
  row counts any `busybox.exe`).
- Against MSVC 14.44 builds of the same extensions: see
  [findings](findings.md#with-the-libraries-php-ships); the same results,
  test by test.

### Reproducibility

| Image | Manifest | Layer |
|---|---|---|
| `net.php.php.Sdk` 8.5.11 | `b8828d57` | 42.3 MB (37.0 before `dev\deps`) |
| `net.php.php` 8.5.11 | `04d03b79` | 37.0 MB, the same layer as iteration 23's (`06dea018`): only its config changed |
| `net.php.php.APCu` 5.1.28 | `5bbe3315` | 75 KB |
| `net.php.php.Xdebug` 3.5.3 | `46ad6a7e` | 169 KB |
| `net.php.php.Igbinary` 3.2.17RC1 | `8596d692` | 61 KB |
| `net.php.php.Redis` 6.3.0 | `1de2cf41` | 231 KB |
| `net.php.php.SSH2` 1.5.0 | `d599ceb4` | 57 KB |

The same in `D:\zs\a` and in `D:\zs\i24\p`, and the test servers' image
(`26d2b26a`, not published) too.

## Decisions made along the way

- **igbinary 3.2.17RC1**, not 3.2.16: 3.2.16 includes
  `php_smart_string.h`, which PHP 8.5 dropped; PECL marks 3.2.17RC1
  stable, and it's the release for 8.5. Its recipe patches two `_MSC_VER`
  tests.
- **redis builds against igbinary's image**, as an SDK, rather than
  igbinary's sources next to it as PHP's in-tree builds have them: it
  links with the DLL the installed igbinary has, through the import
  library and headers `php-ext` now keeps.
- **`needs` orders as well as requires**: redis imports from
  `php_igbinary.dll`, which Windows finds only if PHP loaded it first.
- **libiconv's headers joined the deps**: libxml2's include `iconv.h`;
  `php8.dll` exports libiconv too.
- **The deps' licences stay** in `dev\deps\share`, as the SDK
  redistributes their headers and import libraries.
- **Run as itself, a runtime's own entries in a joined variable come
  last**, as an app's do.

## Findings

See [findings.md](findings.md#with-the-libraries-php-ships).

## Known gaps

See [gaps.md](gaps.md): what runs depends on what's installed; extensions'
aliases and runtimes; libraries PHP doesn't ship; `_MSC_VER` tests;
ssh2's signal test and miniredis.

## For you

- Publish the seven PHP images (`scripts/publish.sh` has the three new
  ones after `php-xdebug.json`; igbinary before redis, which pins it) and
  the catalog, and make the three new packages public.
- Commit and push; then I check both CI jobs and their times.
- Tag v0.24.0 for the release (zigsaw changed); then I check it.

## Suggested for iteration 25

- A library PHP doesn't ship, built with zig in an extension's recipe
  (libzstd for PhpRedis' compression, libyaml).
- Composer, and a PHP app on the runtime.
- Extension points elsewhere: GTK's runtime (GdkPixbuf loaders, GIO
  modules, themes), .NET.
- Thread-safe PHP.
