# Iteration 25: libraries PHP doesn't ship, Composer, and Kanboard

Concluded 2026-10-16.

## Outcome

- **PHP extensions with libraries PHP doesn't ship**: an extension's recipe
  builds the library first, with CMake and zig, into the build's prefix,
  where `php-ext` now looks before PHP's own. New images: **yaml** 2.3.0
  with libyaml 0.2.5 and **zstd** 0.18.0 with libzstd 1.5.7, both static,
  both passing the same tests as php.net's own builds of them.
- **Aliases that run a runtime's file**: an image's alias may start with
  one of its own runtimes' `${alias}`, as its command may. zigsaw 0.25.0.
- **Composer** 2.10.3 as an image on PHP's runtime: an app (`composer`),
  and, as an SDK, a `composer` alias for builds.
- **Kanboard** 1.2.54, a web app on PHP's runtime: its recipe installs its
  dependencies with Composer from its lock file, in a pinned vendor step;
  `kanboard` serves it with PHP's built-in web server and opens it in the
  browser, from a Start menu shortcut too; its database is in the app's
  data. It works under `soft`; under `low`, PHP's `is_writable()` is wrong
  and Kanboard refuses to start (a PHP bug; a fix drafted for php-src).

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-25-vast-lovelace.md`):

- **Libraries PHP doesn't ship, and Composer with a PHP app** (your picks
  of four).
- **Kanboard** as the app (your pick over PHPUnit and phpDocumentor).
- **Composer as its own image, with a zigsaw change** so that its alias can
  run PHP's `php.exe` (your pick over Composer in PHP's SDK).
- Mine: PhpRedis's Windows build has no zstd, so yaml and zstd are the
  proofs, with php.net's own builds of them as the bar; the libraries are
  modules of the extensions' recipes, static, as Flatpak builds libraries
  into the app; the PHP runtime and the five earlier extensions keep their
  SDK pin, as nothing in them changes.
- During: under `--sandbox=low` Kanboard refuses to start, as PHP's
  `is_writable()` leaves out the integrity label; **Kanboard soft only,
  and a fix drafted for php-src** (your pick over patching Kanboard or an
  extension that replaces `is_writable()`).

## What was built

### Aliases that run a runtime's file

- [`src/oci.zig`](../src/oci.zig): `validateAliases` takes the owning
  image's runtimes: an image's own aliases may name them, as its command
  and exports may; those a runtime entry carries still name only the
  runtime's files.
- [`src/aliases.zig`](../src/aliases.zig): a `Provider` has its runtimes'
  directories, which `resolve` expands, in the command and the arguments.
- [`src/builder.zig`](../src/builder.zig) passes an SDK's runtimes (builds
  had them already, for its env); [`src/run.zig`](../src/run.zig) the app's.

### Libraries in an extension's recipe

- [`config-w32.js`](../recipes/php-sdk/config-w32.js): `CHECK_LIB` and
  `CHECK_HEADER_ADD_INCLUDE` search `$PREFIX\lib` and `$PREFIX\include`
  before PHP's `dev\deps`; `CHECK_LIB` returns the library's path, as
  configure's does (yaml reads its name).
- [`php-ext.php`](../recipes/php-sdk/php-ext.php): `$PREFIX\include` on
  every compile's include path; a library named in `$PREFIX\lib` linked by
  its path.
- [`recipes/php-yaml.json`](../recipes/php-yaml.json),
  [`recipes/php-zstd.json`](../recipes/php-zstd.json): the library with
  CMake (the CMake image as an SDK, zig from PHP's SDK), then the
  extension; their headers and static libraries cleaned up, their
  licences kept.

### Composer and Kanboard

- [`recipes/composer.json`](../recipes/composer.json): `composer.phar`,
  PHP's runtime, `composer` as export and alias.
- [`recipes/kanboard.json`](../recipes/kanboard.json): the release tarball,
  `composer.json` and `composer.lock` from the tag's commit (the tarball
  leaves them out), a vendor step running `composer install`,
  `DATA_DIR=${data}`, `PLUGINS_DIR=${data}\plugins`, exports `kanboard`
  and `kanboard-cli`, a Start menu shortcut with Kanboard's icon.
- [`recipes/kanboard/serve.php`](../recipes/kanboard/serve.php): PHP's web
  server on `127.0.0.1:8471` (`--listen`), the browser through Explorer
  (`--no-browser`); [`router.php`](../recipes/kanboard/router.php) keeps
  `app\`, `libs\`, `vendor\` and `cli` from the web.
- `.gitattributes`: `recipes/kanboard/*` with LF, as the image carries them.

### Tests

- Unit tests: aliases naming the image's runtimes (allowed, an unknown one
  and one outside the runtime refused), resolving them, run providers.
- [`tests/build.sh`](../tests/build.sh): the aliases section's app has an
  alias running its runtime's BusyBox, and its SDK one that a build calls.
- [`tests/php.sh`](../tests/php.sh): yaml and zstd build, join PHP's runs
  (seven extensions now), work (zstd with the external library), and pass
  their suites; Composer installs an offline project (a path repository,
  [`tests/php/composer`](../tests/php/composer)) and runs its script under
  soft and low; Kanboard logs in, creates a project through its JSON-RPC
  API and refuses its code directories under soft, `kanboard-cli` makes
  its database in its data, and under low it refuses (known gap).

## Results

### Tests

- Unit tests: 99 (98 + 1).
- `tests/build.sh`: the aliases section alone 23 of 23 (7.5 s), the PHP
  section 8 of 8. CI's `build` job runs all of it.
- `tests/php.sh`: 42 of 42, 5.6 min.
- `sandbox.sh` 78, `shims.sh` 54, `store.sh` 15: all pass. The matrix: as
  intended.
- Against php.net's builds: yaml 76 pass, zstd 61 pass and 5 skipped, both
  ways ([findings](findings.md#with-libraries-php-doesnt-ship)).

### Reproducibility

| Image | Manifest | Layer |
|---|---|---|
| `net.php.php.Sdk` 8.5.11 | `aaff294a` | 42.3 MB (`php-ext` and `config-w32.js` changed) |
| `net.php.php.Yaml` 2.3.0 | `af865a16` | 90 KB |
| `net.php.php.Zstd` 0.18.0 | `e72711ce` | 340 KB |
| `org.getcomposer.composer` 2.10.3 | `5f65e42b` | 840 KB |
| `org.kanboard.Kanboard` 1.2.54 | `e54f20c4` | 3.6 MB |

The same in `D:\zs\a` and in a fresh store, `D:\zs\i25\p`, where
Kanboard's vendor step ran Composer again, from the network, to the same
hash.

## Decisions made along the way

- **libyaml from GitHub's archive of its tag**: the release tarball lacks
  the templates its `CMakeLists.txt` reads.
- **libyaml as `libyaml_a.lib`**, MSVC's name for its static library, which
  yaml's `config.w32` looks for to build against a static libyaml.
- **`DATA_DIR` is the app's data itself**, which exists before the first
  run: Kanboard needs its data directory to exist, and makes `files\` in it.
- **Kanboard in `kanboard\` of the image**, served from there, with
  `serve.php` and `router.php` outside what the server serves.
- **The browser opens through Explorer**, so that it runs outside the
  app's job and doesn't end with the server.
- **Port 8471** by default, less likely taken than 8080.

## Findings

See [findings.md](findings.md#with-libraries-php-doesnt-ship): PhpRedis
without zstd on Windows, libyaml's tarball, `CHECK_LIB`'s return,
`is_writable()` at low integrity, Kanboard's tarball and `vendor\`, PHP's
web server and `.htaccess`.

## Known gaps

See [gaps.md](gaps.md): DLLs an extension's recipe builds; `is_writable()`
at low integrity, and Kanboard under low and in an AppContainer; PHP's web
server for one person; Composer's self-update; zigsaw 0.24 and Composer's
image.

## For you

- Publish the five images and the catalog:
  `scripts/publish.sh recipes/php-sdk.json recipes/php-yaml.json recipes/php-zstd.json recipes/composer.json recipes/kanboard.json`
  (Composer before Kanboard, which pins it), and make the four new
  packages public.
- File the php-src issue drafted in `D:\zs\i25\upstream\php-is-writable.md`.
- Commit and push; then I check both CI jobs and their times.
- Tag v0.25.0 for the release; then I check it.

## Suggested for iteration 26

- Extension points elsewhere: GTK's runtime (GdkPixbuf loaders, which would
  give Pinta WebP; GIO modules; hunspell dictionaries), .NET.
- Thread-safe PHP.
- An extension that needs a DLL PHP doesn't ship.
- Kanboard under `low`, once PHP's fix lands, or with a workaround.
