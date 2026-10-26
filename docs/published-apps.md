# Published apps

The recipes in [recipes/](../recipes/) are published as images in
`ghcr.io/zigsaw-io`, tagged with their version and `latest`, and listed in
its catalog (`zigsaw search`), so these install with `zigsaw pull <id>`
(those in `recipes/no-publish/` aren't: see
[Apps you build yourself](#apps-you-build-yourself)):

| App | Id | Version | Commands |
|---|---|---|---|
| BusyBox | `net.frippery.busybox` | FRP-6075-g169694ebd | `busybox` |
| Git (MinGit) | `org.git_scm.MinGit` | 2.56.0.windows.1 | `git` |
| Node.js | `org.nodejs.node` | 24.21.0 | `node`, `npm`, `npx` |
| Prettier (on Node.js) | `io.prettier.prettier` | 3.9.9 | `prettier` |
| Python | `org.python.python` | 3.14.7 | `python` |
| zig | `org.ziglang.zig` | 0.16.0 | `zig` |
| SQLite (built from source) | `org.sqlite.sqlite3` | 3.53.4 | `sqlite3` |
| Rust (windows-gnu) | `org.rust-lang.rust` | 1.99.0 | `cargo`, `rustc` |
| ripgrep (built from source) | `com.github.BurntSushi.ripgrep` | 15.2.0 | `rg` |
| bat (built from source) | `com.github.sharkdp.bat` | 0.26.1 | `bat` |
| Go | `org.golang.go` | 1.27.1 | `go`, `gofmt` |
| fzf (built from source) | `com.github.junegunn.fzf` | 0.74.4 | `fzf` |
| zot, minimal (built from source) | `dev.zotregistry.zot` | 2.1.21 | `zot` |
| CMake, with Ninja 1.13.2 | `org.cmake.cmake` | 4.4.4 | `cmake`, `ctest`, `cpack`, `ninja` |
| zstd (built from source) | `com.github.facebook.zstd` | 1.5.7 | `zstd`, `unzstd`, `zstdcat` |
| Meson, with Ninja and pkgconf | `com.mesonbuild.meson` | 1.12.1 | `meson` |
| ZLS, the Zig language server (built from source with zig, on zig) | `org.zigtools.zls` | 0.16.1 | `zls` |
| Perl (Strawberry Perl, for building OpenSSL and Gnumeric) | `org.perl.perl` | 5.42.3.1 | `perl` |
| cargo-c (for building librsvg) | `com.github.lu-zero.cargo-c` | 0.10.25 | `cargo-cbuild`, `cargo-cinstall` |
| GNU gettext, with libiconv (built from source, for GTK's SDK) | `org.gnu.gettext` | 1.0 | `gettext`, `ngettext`, `msgfmt`, `msgmerge`, `msginit`, `msgcat`, `msgunfmt`, `xgettext`, `iconv` |
| GTK SDK's first half: GTK and the stack below it (built from source, for GTK's SDK) | `org.gtk.Gtk4.Sdk.Base` | 4.24.1 | |
| GTK SDK (built from source, with introspection data; with zig, Meson and BusyBox) | `org.gtk.Gtk4.Sdk` | 4.24.1 | `cc`, `c++`, `ar`, `rc`, `windres`, `nm`, `pkg-config`, `meson`, `ninja`, `sh`, `make`, `glib-compile-resources`, `glib-compile-schemas`, `gtk4-builder-tool`, `msgfmt`, `msgmerge`, `xgettext`, `g-ir-scanner`, `g-ir-compiler` |
| GTK, with libadwaita, libsoup, librsvg and enchant (from its SDK) | `org.gtk.Gtk4` | 4.24.1 | `gtk4-demo`, `gtk4-widget-factory`, `gtk4-node-editor`, `gtk4-print-editor`, `gtk4-query-settings`, `adwaita-1-demo`, `gio`, `pango-view`, `pango-list` |
| Vietnamese dictionary for GTK apps (extends GTK's runtime) | `org.gtk.Gtk4.Hunspell.vi_VN` | 1.0.45 | |
| French dictionary for GTK apps (extends GTK's runtime) | `org.gtk.Gtk4.Hunspell.fr_FR` | 7.0 | |
| GNOME Text Editor (built from source, on GTK) | `org.gnome.TextEditor` | 51.0 | `gnome-text-editor` |
| Rnote (built from source, on GTK) | `com.github.flxzt.rnote` | 0.14.2 | `rnote`, `rnote-cli` |
| GTK 3 SDK (built from source, with GTK's SDK) | `org.gtk.Gtk3.Sdk` | 3.24.52 | |
| GTK 3 (from its SDK; with GTK's runtime) | `org.gtk.Gtk3` | 3.24.52 | |
| GTK 3's demos (on GTK and GTK 3) | `org.gtk.Gtk3demo` | 3.24.52 | `gtk3-demo`, `gtk3-widget-factory`, `gtk3-icon-browser` |
| Gnumeric (built from source, on GTK and GTK 3) | `org.gnome.Gnumeric` | 1.12.62 | `gnumeric`, `ssconvert`, `ssindex`, `ssgrep`, `ssdiff` |
| PyGObject SDK, with Python 3.14 and pycairo (built with GTK's SDK) | `org.gnome.PyGObject.Sdk` | 3.58.1 | |
| PyGObject, with Python 3.14 and pycairo (from its SDK) | `org.gnome.PyGObject` | 3.58.1 | |
| Meld (built from source, on GTK, GTK 3 and PyGObject) | `org.gnome.Meld` | 3.24.1 | `meld` |
| Gaphor, with Graphviz's dot (built from source, on GTK and PyGObject; packages from PyPI) | `org.gaphor.Gaphor` | 3.3.2 | `gaphor` |
| 7-Zip | `org.7_zip.7zip` | 26.04 | `7z`, `7zfm`, `7zg` |
| Notepad++ | `org.notepad_plus_plus.NotepadPlusPlus` | 8.9.8.1 | `notepad++` |
| SumatraPDF | `org.sumatrapdfreader.SumatraPDF` | 3.6.1 | `sumatrapdf` |
| VLC media player | `org.videolan.VLC` | 3.0.24 | `vlc` |
| PHP SDK, with php-ext (with zig, BusyBox and Node) | `net.php.php.Sdk` | 8.5.11 | `php-ext` |
| PHP (from its SDK) | `net.php.php` | 8.5.11 | `php`, `php-cgi`, `phpdbg` |
| APCu for PHP 8.5 (built from source) | `net.php.php.APCu` | 5.1.28 | |
| Xdebug for PHP 8.5 (built from source) | `net.php.php.Xdebug` | 3.5.3 | |
| igbinary for PHP 8.5 (built from source) | `net.php.php.Igbinary` | 3.2.17RC1 | |
| PhpRedis for PHP 8.5 (built from source) | `net.php.php.Redis` | 6.3.0 | |
| SSH2 for PHP 8.5 (built from source) | `net.php.php.SSH2` | 1.5.0 | |
| YAML for PHP 8.5, with libyaml (built from source) | `net.php.php.Yaml` | 2.3.0 | |
| Zstandard for PHP 8.5, with libzstd (built from source) | `net.php.php.Zstd` | 0.18.0 | |
| Composer (on PHP) | `org.getcomposer.composer` | 2.10.3 | `composer` |
| Kanboard (on PHP; dependencies installed by Composer) | `org.kanboard.Kanboard` | 1.2.54 | `kanboard`, `kanboard-cli` |
| OpenJDK, Eclipse Temurin's JDK | `org.openjdk.java.Sdk` | 25.0.5_7-ea | `java`, `javaw`, `javac`, `jar`, `jshell`, `javadoc`, `jdeps`, `jlink`, `keytool` |
| OpenJDK Runtime, Eclipse Temurin's JRE | `org.openjdk.java` | 25.0.5_7-ea | |
| Apache Maven (on the JDK) | `org.apache.maven` | 3.10.0 | `mvn` |
| Gradle (on the JDK) | `org.gradle.gradle` | 9.8.1 | `gradle`, `gradle-vendor` |
| Apache PDFBox (built from source with Maven, on Java's runtime) | `org.apache.pdfbox` | 3.0.8 | `pdfbox`, `pdfbox-debugger` |
| PlantUML (built from source with Gradle, on Java's runtime) | `com.plantuml.PlantUML` | 1.2026.9 | `plantuml`, `plantuml-gui` |
| Logisim-evolution (built from source with Gradle, on Java's runtime) | `com.github.reds.LogisimEvolution` | 5.0.0 | `logisim`, `logisim-gui` |
| Scene Builder (built from source with Maven, with OpenJFX, on the JDK) | `com.gluonhq.SceneBuilder` | 26.0.0 | `scenebuilder` |
| Qt 6 SDK's first half: qtbase and the modules before QML (built from source, for Qt's SDK) | `io.qt.Qt6.Sdk.Base` | 6.12.0 | |
| Qt 6 SDK, the Widgets set with QML and Qt Quick (built from source; with zig, CMake and BusyBox) | `io.qt.Qt6.Sdk` | 6.12.0 | `cc`, `c++`, `ar`, `rc`, `cmake`, `ninja`, `sh`, `make`, `qmake`, `qtpaths`, `lupdate`, `lrelease` |
| Qt 6, with Qt Widgets Designer and Qt Linguist (from its SDK) | `io.qt.Qt6` | 6.12.0 | `designer`, `linguist`, `pixeltool`, `qml`, `qtdiag` |
| Flameshot (built from source, on Qt) | `org.flameshot.Flameshot` | 14.0.0 | `flameshot` |
| Notes (built from source, on Qt Quick) | `io.github.nuttyartist.notes` | 2.3.1 | `notes` |
| Ghostscript (built from source) | `com.artifex.Ghostscript` | 10.08.0 | `gs`, `gswin64c` |
| TeX Live, its small scheme (on Perl and Ghostscript; packages from tlnet) | `org.tug.texlive` | 2026.80721 | `latexmk`, `pdflatex`, `xelatex`, `lualatex`, `latex`, `tex`, `bibtex`, `biber`, `makeindex`, `mpost`, `kpsewhich`, `dvips`, `dvipdfmx`, `epstopdf`, `ps2pdf` and 116 more |
| GNU Make (built from source, for builds) | `org.gnu.make` | 4.4.1 | |
| PostgreSQL SDK: PostgreSQL built from source with zig, with headers, libraries and pgxs | `org.postgresql.PostgreSQL.Sdk` | 18.6 | `pg_config` |
| PostgreSQL, with PL/Perl and PL/Python (from its SDK; on Perl and Python) | `org.postgresql.PostgreSQL` | 18.6 | `postgresql`, `postgres`, `initdb`, `pg_ctl`, `psql`, `pg_dump`, `pg_dumpall`, `pg_restore`, `pg_basebackup`, `pg_isready`, `createdb`, `dropdb`, `createuser`, `dropuser`, `vacuumdb`, `reindexdb`, `clusterdb`, `pgbench` |
| pgvector, extending PostgreSQL (built from source with pgxs) | `org.postgresql.PostgreSQL.pgvector` | 0.8.7 | |
| pg_cron, extending PostgreSQL (built from source with pgxs) | `org.postgresql.PostgreSQL.pg_cron` | 1.6.8 | |
| GDAL SDK: GDAL built from source with zig, with GEOS, PROJ, SQLite, json-c and expat as static libraries | `org.gdal.GDAL.Sdk` | 3.13.3 | |
| GDAL, its raster and vector tools (from its SDK) | `org.gdal.GDAL` | 3.13.3 | `gdal`, `gdalinfo`, `gdal_translate`, `gdalwarp`, `ogr2ogr`, `ogrinfo`, `gdalsrsinfo`, `gdaltransform`, `gdal_create` and 20 more |
| PostGIS, extending PostgreSQL (built from source, on GDAL's SDK; with rasters) | `org.postgresql.PostgreSQL.PostGIS` | 3.6.4 | |
| osm2pgsql, which imports OpenStreetMap data into PostGIS (built from source with zig, on PostgreSQL's and GDAL's SDKs) | `org.osm2pgsql.osm2pgsql` | 2.3.1 | `osm2pgsql`, `osm2pgsql-expire` |

Prettier runs on Node as a [runtime](#runtimes): its image brings Node's
files along, without installing Node as an app. SQLite, ripgrep, bat, fzf,
zot and zstd are [built from source](#building-from-source): SQLite with zig
and BusyBox, ripgrep and bat with [Rust](#rust), zig and BusyBox, fzf and
zot with [Go](#go) and BusyBox, zstd with [CMake](#cmake), zig and BusyBox,
whose images are their SDK. bat's C libraries (oniguruma, libgit2, zlib) are
compiled by zig. Pulling them doesn't need those. ZLS, the language server
for Zig, is built with `zig build`, its packages fetched in a
[vendor step](recipes.md#zig), and runs on zig's image, which it finds
on its PATH: point an editor at its `zls` command. [GTK](#gtk)'s SDK is built
with Meson, CMake, zig, Perl (for OpenSSL), Rust and cargo-c (for librsvg),
takes gettext's files from its image, and has zig, Meson and BusyBox as
runtimes, so that it builds GTK programs
[without a recipe](#building-without-a-recipe) too; its runtime is made from
the SDK's image. GNOME Text Editor runs on GTK's runtime, with GtkSourceView
and libspelling built into its own image, and checks spelling. Rnote, a
drawing and note-taking app written in Rust, runs on it too. GTK, Text Editor
and Rnote are translated. GTK's demos, Text Editor and Rnote are GUI apps:
they open no console, and get [Start menu shortcuts](#start-menu-shortcuts)
with their icons. Explorer offers Rnote for `.rnote` and `.xopp` files and
Text Editor for `.txt`, `.md` and `.log` ([file associations](#file-associations)).
[GTK 3](recipes.md#gtk-3)'s images add GTK 3 and ATK to GTK's, which
have the rest of what it's built on: a GTK 3 app lists both runtimes.
Gnumeric, a spreadsheet that reads and writes Excel and OpenDocument, runs
on them, with its command-line converter `ssconvert`; Explorer offers it
for `.gnumeric`, `.xlsx`, `.xls`, `.ods` and `.csv`. GTK's images carry
their libraries' introspection data, which [PyGObject](recipes.md#python-apps)'s
images, Python with GTK's Python binding, load: Meld, a Python app that
compares and merges files and folders, runs on GTK 3 that way, and Gaphor,
a UML and SysML modeller, on GTK 4 and libadwaita, with its packages from
PyPI pinned by a [vendor step](recipes.md#packages-from-pypi).
GTK's runtime has an [extension point](recipes.md#gtks-data-directories-and-extensions):
installed, the Vietnamese and French dictionaries join every GTK app's
spell checking.
[Qt 6](recipes.md#qt)'s SDK builds Qt's Widgets set, QML and Qt Quick from
source with CMake and zig, in two halves (qtbase, qtsvg, qtimageformats and
qtshadertools; then qtdeclarative, qttools and qttranslations), with CMake,
zig and BusyBox as runtimes, so it builds Qt programs without a recipe too;
its runtime, made from it, runs Qt Widgets Designer and Qt Linguist and gets
their shortcuts, and its `qml` runs QML files. Flameshot, a screenshot tool,
runs on it, in its tray, and `flameshot full --path <dir>` saves a
screenshot from the command line, in every sandbox; Notes, a note-taking
app whose kanban board is Qt Quick, opens in every sandbox too.
7-Zip, Notepad++, SumatraPDF and VLC are the programs their projects
publish, packaged from upstream's archives, with shortcuts and the kinds of
file they open ([prebuilt GUI apps](#prebuilt-gui-apps)). 7-Zip's image is
made from its installer, which its standalone `7zr.exe` unpacks.
PHP is php.net's own Windows build, and needs Microsoft's Visual C++
Redistributable installed, as that does. Its SDK's `php-ext` builds PHP
extensions from source with zig, from their `config.w32`, against PHP and
the libraries it ships (OpenSSL, libssh2, zlib...), as the extensions'
images are; YAML's and Zstandard's recipes build their library first, with
CMake and zig. Installed, an extension joins every run of PHP, through PHP's
[extension point](recipes.md#extension-points); `--noextension`
leaves it out ([PHP](recipes.md#php)). Composer runs on PHP's runtime,
and as an SDK gives builds a `composer` command: Kanboard's recipe installs
its dependencies with it, from their lock file. Kanboard is a web app:
`kanboard` serves it with PHP's built-in web server on `127.0.0.1:8471` and
opens it in your browser (its Start menu shortcut does that too), with its
database in the app's data.
[Java](recipes.md#java)'s images are Eclipse Temurin's builds of
OpenJDK 25: Java apps run on its JRE, and its JDK builds them, with Maven or
Gradle, whose images run on it and whose dependencies a recipe pins with a
vendor step. Java finds the user's profile without the environment, so the
images point its `user.home` into the app's data. PDFBox, a toolkit for PDF
documents, PlantUML, which draws diagrams from text, and Logisim-evolution,
which designs and simulates logic circuits, are built that way; PDFBox's
debugger opens `.pdf` files and Logisim `.circ` files, and all three keep
their settings with the app. So is Scene Builder, which designs JavaFX
user interfaces: it brings its own JavaFX (OpenJFX) and opens `.fxml`
files.
[PostgreSQL](recipes.md#postgresql) is built from source with Meson and
zig, with OpenSSL, zlib, lz4, zstd and libxml2 built in, ICU from Windows'
own `icu.dll`, and PL/Perl and PL/Python on Perl's and Python's images as
runtimes. `postgresql` runs the server in the foreground, on `localhost:5432`
(`postgresql -p 5433` for another port): its first run makes a cluster in
the app's data, UTF-8 in the builtin `C.UTF-8` locale, with a random
password for the `postgres` user, which the app's own clients (`psql`,
`pg_dump`...) find in its password file there. The server lasts as long as
its run: `pg_ctl stop`, or Ctrl+C, stops it, and `pg_ctl start` doesn't
outlive its own run. Installed beside it, pgvector, pg_cron and PostGIS join
every run of its server as [extensions](recipes.md#postgresql-extensions):
`CREATE EXTENSION vector` or `CREATE EXTENSION postgis` in a database, or
`CREATE EXTENSION pg_cron` in `postgres`, which the server preloads. PostGIS's
rasters (`CREATE EXTENSION postgis_raster`) are on [GDAL](recipes.md#gdal),
whose tools are an image of their own: `gdalinfo`, `gdalwarp`, `ogr2ogr`
and the rest read and write files in the directory they're run from.
[osm2pgsql](recipes.md#osm2pgsql) imports OpenStreetMap data (`.osm.pbf`,
`.osm`, compressed or not, and change files for updates) from the directory
it's run from into a PostGIS database: `osm2pgsql -U postgres -W -d <db>
<file>` asks for the password `postgresql` made, which is in PostgreSQL's
data (`pgpass.conf`); osm2pgsql can't read that, as it's another app's. It
reaches a server running under soft or low, or on another machine, but not
one on this machine from an AppContainer.

Layers are gzip-compressed, so a pull downloads much less than it unpacks:
88 MB for zig's 378 MB of files, 179 MB for Rust's 649 MB.

[`scripts/publish.sh`](../scripts/publish.sh) publishes the recipes listed in
[`scripts/published-recipes.txt`](../scripts/published-recipes.txt).

## Apps you build yourself

The recipes in [recipes/no-publish/](../recipes/no-publish/) make images that
mustn't be published, as the licences of what's in them don't allow it.
`zigsaw pull` can't find them: each machine builds them, in this order.

| App | Id | Version | Commands |
|---|---|---|---|
| .NET SDK | `com.microsoft.dotnet.Sdk` | 10.0.402 | `dotnet`, `dnx` |
| .NET runtime, with ASP.NET Core and Windows Desktop (from its SDK) | `com.microsoft.dotnet` | 10.0.13 | |
| Pinta (built from source, on GTK and .NET) | `com.github.PintaProject.Pinta` | 3.1.2 | `pinta` |
| Files - Zigsaw build (built from source, on .NET) | `community.files.Files` | 4.3 | `files` |

```powershell
zigsaw build recipes\no-publish\dotnet-sdk.json   # 300 MB from Microsoft
zigsaw build recipes\no-publish\dotnet.json
zigsaw build recipes\no-publish\pinta.json
zigsaw build recipes\no-publish\files.json        # 3.3 GB of NuGet packages; about ten minutes
```

Microsoft's licence for its .NET binaries on Windows lets anyone use them
to build and test programs, and ship them in their own, but not publish
them for others to copy ([.NET](recipes.md#net)). Pinta, an image
editor written in C#, runs on GTK's runtime and .NET's: its build pulls
GTK's runtime and gettext's image from the registry, and finds .NET's in the
store. Explorer offers it for images (`.ora`, `.png`, `.jpg`, `.bmp`,
`.tif`).

[Files](https://files.community/), a file manager written in C# with
WinUI 3, runs on .NET's runtime, patched to run without the MSIX package
it's made for ([Files](recipes.md#files)). Its window and Start menu
shortcut say "Files - Zigsaw build", so as not to pass for the Files its
project publishes. It works in the default `soft` sandbox only: at low
integrity and in an AppContainer it starts, but shows no drives and asks
for a permission it can't be given.

## Reproducibility

Each image has the same digest as a build of its recipe on any machine:
sources are pinned by SHA-256, runtimes by image digest, and builds write
deterministic layers. The
[Reproduce workflow](../.github/workflows/reproduce.yml)
([runs](https://github.com/zigsaw-io/zigsaw/actions/workflows/reproduce.yml))
checks this on every push to `main` and every pull request. On fresh
Windows runners, it builds each published recipe and compares the digest
with the image published for the recipe's version
([`tests/published.sh`](../tests/published.sh)), in parallel jobs, one for each
group of [`scripts/published-groups.txt`](../scripts/published-groups.txt).
Beside them, it runs the unit tests and the end-to-end suites (see
[Testing](#testing)), `tests/build.sh` in jobs of its own, one for each
group of its sections. GTK's family, whose builds take most of a run (GTK's
SDK alone is 55 minutes on a runner), is checked only when something it's
built or tested from changed since the last commit a run passed on
([`scripts/ci-groups.sh`](../scripts/ci-groups.sh)), and by a weekly run that
checks everything.

- A version that isn't published yet is reported, but doesn't fail the run.
- A different digest for the same version fails it. Either the build isn't
  reproducible, or the recipe changed without a new version.
- An image built with a host toolchain (e.g MSVC) isn't compared, since it
  isn't expected to match. (None of the published ones is.)
- Every image a published recipe pins, as a runtime, an SDK or an image
  source, must be on the registry, so a fresh store can build the recipe
  ([`scripts/check-pins.sh`](../scripts/check-pins.sh), in a job of its own,
  and at the end of `publish.sh`). A runtime pinned at an older build than
  its tag is reported, but doesn't fail the run.

The workflow only checks. Images are published by hand
([`scripts/publish.sh`](../scripts/publish.sh)); zigsaw's own releases by the
Release workflow (see [Installing zigsaw](#installing-zigsaw)).
