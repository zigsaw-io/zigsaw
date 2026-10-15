# Iteration 23: PHP, and its extensions built with zig

Concluded 2026-10-16.

## Outcome

- **PHP 8.5.11** as images made from php.net's own Windows build (NTS,
  x64): an SDK, `net.php.php.Sdk`, with PHP's devel pack and `php-ext`, and
  the runtime, `net.php.php`, made from the SDK image's files, which is also
  the `php` command. It reads only its own `php.ini`, with ten of PHP's
  extensions on, and HTTPS works through curl and streams. It runs in all
  three sandboxes, with the Visual C++ runtime the machine has.
- **PHP extensions built without MSVC.** `php-ext` runs an extension's
  `config.w32` under Node, as PHP's configure would, and builds it with
  zig's clang, for PHP's MSVC build. APCu 5.1.28 and Xdebug 3.5.3, built
  that way, pass their own test suites (56 and 745 tests), as their MSVC
  builds do.
- **Extensions as images** that apps list as runtimes next to PHP's, loaded
  through the `.ini` each carries: `net.php.php.APCu` and
  `net.php.php.Xdebug`. Both work in all three sandboxes; Xdebug's step
  debugger reaches an IDE except in an AppContainer.
- zigsaw itself didn't change.

## Starting decisions

From the planning session (plan file
`plan-for-iteration-23-zippy-unicorn.md`), after a probe that same day
which found that zig can build extensions for PHP's official build
([findings](findings.md#php-extensions-without-msvc)):

- **The Visual C++ runtime is the machine's** (your pick): PHP's DLLs find
  it in System32, as php.net's zip expects; the images stay publishable.
- **Extensions are images used as runtimes** (your pick), each with a
  `conf.d` that an app names in `PHP_INI_SCAN_DIR`; no zigsaw change.
- **`php-ext` reads `config.w32`** (your pick), with Node's image as one of
  the SDK's runtimes.
- **Proofs: Xdebug and APCu** (your pick), with their test suites, and a
  small test extension for CI.
- Mine: PHP 8.5.11 NTS x64; ids `net.php.php`, `.Sdk`, `.APCu`, `.Xdebug`;
  sources from `downloads.php.net/~windows/releases/archives/`, which keeps
  every release (`releases/` drops each once the next is out); the SDK
  holds PHP, as an alias runs only an executable in its own image; an
  extension image's command is an `about.bat`.

## What was built

### The images

- [`recipes/php-sdk.json`](../recipes/php-sdk.json): PHP's zip, its devel
  pack in `dev`, curl.se's certificates, our `php.ini`, and the zig kit and
  `php-ext` in `dev\zigsaw`. Runtimes zig, BusyBox and Node; exports
  `php-ext`, also as an alias for builds.
- [`recipes/php.json`](../recipes/php.json): the SDK image without `dev`.
  Exports `php`, `php-cgi`, `phpdbg`.
- [`recipes/php-apcu.json`](../recipes/php-apcu.json),
  [`recipes/php-xdebug.json`](../recipes/php-xdebug.json): `php-ext build`
  of PECL's release tarballs.

### php-ext

[`php-ext.php`](../recipes/php-sdk/php-ext.php), run by the SDK's PHP:

- `build` runs [`config-w32.js`](../recipes/php-sdk/config-w32.js) under
  Node, which evaluates `config.w32` with stand-ins for confutils.js's
  functions and the official build's `ext_deps.js`, then compiles in
  parallel with zig's `cc` and links with `php8.lib` and the libraries PHP
  links every extension with. It writes the DLL, a `conf.d\<ext>.ini` that
  loads it from `${PHP_EXT_<EXT>}`, and `about.bat`.
- `test` runs `run-tests.php` (or the extension's own, `--runner`) with the
  SDK's PHP and the DLL, then reruns failures one at a time.

[`zig-php.h`](../recipes/php-sdk/zig-php.h) and
[`zig-php.c`](../recipes/php-sdk/zig-php.c) are what clang needs to build
for MSVC's PHP ([recipes guide](recipes.md#what-zig-needs-to-build-for-msvcs-php)).

### Tests

- [`tests/build.sh`](../tests/build.sh) has a PHP section (7 checks, in
  CI): the SDK and runtime build; a test extension
  ([`tests/build/php`](../tests/build/php)), whose `config.w32` uses
  `ADD_SOURCES` with a subdirectory, a string `AC_DEFINE`, an option's
  value and `CHECK_LIB`, builds into an image and reproduces; an app with
  it and PHP as runtimes passes its 26 checks in each sandbox; `php-ext`
  builds it without a recipe, and the runtime loads it from there.
- [`tests/php.sh`](../tests/php.sh) (18 checks, local, about 100 s with the
  images built): the runtime in each sandbox, its files, HTTPS; the
  extension images' files and `about.bat`; APCu's and Xdebug's suites; an
  app with PHP, APCu and Xdebug as runtimes in each sandbox; Xdebug's step
  debugger reaching a DBGp client ([`tests/php/listener.php`](../tests/php/listener.php))
  under `soft` and `low`, and not in an AppContainer.

### Code map

- New: `recipes/php-sdk.json`, `recipes/php-sdk/` (`php.ini`,
  `zig-php.h`, `zig-php.c`, `php-ext.php`, `config-w32.js`),
  `recipes/php.json`, `recipes/php-apcu.json`, `recipes/php-xdebug.json`,
  `tests/build/php/`, `tests/php/`, `tests/php.sh`.
- Changed: `tests/build.sh`, `scripts/published-recipes.txt`, `README.md`,
  `docs/recipes.md`, `docs/findings.md`, `docs/gaps.md`.

## Results

### Tests

- `tests/build.sh`'s PHP section, in a fresh store whose zig, BusyBox and
  Node came from ghcr.io: 7 of 7, 117 s.
- `tests/php.sh`: 18 of 18, 102 s.
- MSVC 14.44 builds of APCu and Xdebug, run the same way: 56 and 745
  tests pass, the same as zig's.
- Not run: the rest of `build.sh` and the other suites, as zigsaw didn't
  change; `published.sh` until the four images are published.

### Reproducibility

| Image | Manifest | Layer |
|---|---|---|
| `net.php.php.Sdk` 8.5.11 | `29cab2e0` | 37.0 MB |
| `net.php.php` 8.5.11 | `6fc69628` | 35.3 MB, for 95 MB of files |
| `net.php.php.APCu` 5.1.28 | `973f86ac` | 58 KB |
| `net.php.php.Xdebug` 3.5.3 | `c6f8923c` | 164 KB |

The same in `D:\zs\a` and in a fresh store, `D:\zs\i23\p`; the test
extension's image too, built again.

## Decisions made along the way

- **curl gets Mozilla's certificates** (`curl.cainfo`, curl.se's dated
  bundle, pinned): PHP's libcurl is OpenSSL's only, and can use Windows'
  stores only per request (`CURLSSLOPT_NATIVE_CA`), which no `php.ini`
  setting asks for. Streams keep Windows' stores.
- **`zig-php.h` also leaves out MinGW's `P_tmpdir`, `PATH_MAX` and
  `NAME_MAX`**, found when Xdebug's gcstats and profiler tests failed run
  from `C:` (its default output directory had become the drive's root), and
  MinGW's `S_IRUSR`... and `gettimeofday`, which PHP's headers define
  again.
- **The DLL's import library stays out of the image**
  (`--out-implib` into the build's directory): zig writes one next to the
  DLL, named after the first object.
- **`php-ext test` takes run-tests.php's options after `--`**, and fails for
  a test path that doesn't exist: run-tests.php runs nothing for one, and
  passes. It passes the extensions in `TEST_PHP_ARGS` only, which
  run-tests.php reads as its own options too (given twice, they load
  twice), and which APCu's server tests and Xdebug's debugger client need.
- **`--runner`**: Xdebug's tests use placeholders (`{TMPFILE:}`) and a
  section (`AFTER`) that only its own copy of run-tests.php knows. It runs
  where it is; PHP's runs from a copy, as it writes a file next to itself.
- `__DATE__` warnings are off (`-Wno-date-time`), as builds fix the date
  with `SOURCE_DATE_EPOCH`.

## Findings

See [findings.md](findings.md#php-extensions-without-msvc): what zig needs,
the comparison with MSVC 14.44, PHP's linker check (which refuses Visual
Studio 18's MSVC 14.51 too), and why GCC and GNU ld don't fit.

## Known gaps

See [gaps.md](gaps.md): the Visual C++ Redistributable, Xdebug's debugger
in an AppContainer, extensions loading only in apps that list them, those
needing PHP's third-party libraries, and MinGW's POSIX names.

## For you

- Publish the four images (`scripts/publish.sh` has them, after `vlc.json`)
  and the catalog, make the four packages public, then commit and push; CI's
  `build.sh` then builds PHP's images on a runner, and `published.sh` checks
  them.

## Suggested for iteration 24

- Extensions that need PHP's third-party libraries (zlib for Xdebug's
  compression, OpenSSL, libxml2): from PHP's own dependency packages
  (windows.php.net's "deps"), or built with zig.
- Composer, and a PHP app on the runtime, as Prettier is on Node's.
- Installed extensions that `php` loads by itself, as Flatpak's runtime
  extensions: a zigsaw feature.
- Thread-safe PHP, for servers that run PHP in threads.
