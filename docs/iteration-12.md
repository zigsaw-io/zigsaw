# Iteration 12: HTTP and SVG for GTK

Concluded 2026-10-06.

## Outcome

Iteration 11 put GTK apps on the desktop, but GTK's images had no HTTP
library and no SVG loader: GTK's widget factory aborted at startup, and an
app that wanted the network had to bring its own stack. GTK's SDK and
runtime now have:

- **libsoup 3.8**, with GIO's TLS from glib-networking's OpenSSL module,
  which trusts Windows' certificate stores, HTTP/2 through nghttp2, the
  Public Suffix List through libpsl, and SQLite. HTTPS works in all three
  sandboxes;
- **librsvg 2.63** and its GdkPixbuf loader, so SVGs load wherever
  GdkPixbuf loads images, and **GTK's widget factory runs again**, exported
  and in the Start menu;
- FreeType and libxml2, which librsvg needs. libxml2 moves out of GNOME
  Text Editor's image into GTK's.

Two new SDK images build them: **`org.perl.perl`** (Strawberry Perl, for
OpenSSL's `Configure`) and **`com.github.lu-zero.cargo-c`** (cargo-c, for
librsvg's Rust code).

Building cargo-c from source found a defect from iteration 5: a Rust
program that GNU ld links can come out with imports the loader never binds,
when its crates call Windows through `raw-dylib`, and it crashes when it
calls one. ripgrep and bat aren't affected. cargo-c's image is its upstream
release for now, librsvg is built around it, and the fix waits for
iteration 13.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-12-streamed-dusk.md`):

- Scope, the user's choice: librsvg from the iteration-11 candidates, and
  libsoup (the user's addition). Not this time: HarfBuzz with DirectWrite,
  spell checking, shortcut icons, file associations, GTK back in CI.
- libsoup goes **into GTK's SDK and runtime**, as in GNOME's runtime, with a
  test program as proof rather than an app.
- TLS: **OpenSSL 3.5 LTS from source**, its `Configure` run by a **prebuilt
  Strawberry Perl image**, over GnuTLS (nettle, GMP, autotools), LibreSSL
  (untested with glib-networking) and WrapDB's OpenSSL 3.0 (end of life in
  September 2026).
- librsvg's build needs cargo-c; the plan was **cargo-c from source**, as
  ripgrep and bat are built (changed along the way, below).

Defaults chosen in the plan: OpenSSL static, linked into glib-networking's
module; the new modules appended to the SDK, earlier ones unchanged; Perl
and cargo-c published but skipped in CI, like GTK; GTK's images keep
version 4.24.1, their tags overwritten when republished.

Planning also confirmed that iteration 11's images were republished
(ghcr.io had GTK's SDK `ef47240f`, runtime `2a869bf2` and Text Editor 51.0)
and that its Reproduce run was green (49.5 of 60 minutes).

## What was built

**Perl** ([`recipes/perl.json`](../recipes/perl.json)). Strawberry Perl
5.42.3.1's portable release as a prebuilt module, without its bundled MinGW
toolchain, CPAN cache and site directory: 161 MB, 41 MB compressed. It runs
in builds with nothing from the host.

**OpenSSL** (in [`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json)).
OpenSSL 3.5.9, `mingw64` target, static, without assembly, apps, tests or
docs. Two things stood in the way:

- `Configure` refuses Strawberry Perl for `mingw64`: it checks that
  `File::Spec` makes forward-slash paths, as MSYS2's Perl does. The module
  loads [`openssl-unixspec.pm`](../recipes/gtk4-sdk/openssl-unixspec.pm)
  into every Perl it runs (`PERL5OPT`), which gives `File::Spec` its Unix
  flavour, counts drive letters as absolute, and folds `dir/..` the way
  `realpath` does on Unix (without that, include paths such as
  `ssl/../libssl` lost every `-I` flag). BusyBox's `make` then builds from
  OpenSSL's Unix makefile.
- BusyBox's `make` runs one job at a time: 16 minutes for OpenSSL's 1,100
  files. The recipe makes the generated sources first, compiles the objects
  from `make -n`'s list with `xargs -P $(nproc)`, and lets `make` archive
  them: 75 seconds.

**libsoup and its stack.** SQLite 3.53.4 (the amalgamation with WrapDB's
Meson files, as libffi has), nghttp2 1.70.0 (CMake, library only), libpsl
0.23.3 (Meson, built-in list, no IDNA library: zig's headers have no
`icu.h` for Windows' own ICU), glib-networking 2.90.0 (OpenSSL backend,
proxies from the environment) and libsoup 3.8.0 (no GSSAPI, NTLM, Brotli or
zstd). glib-networking opens Windows' `ROOT` and `CA` stores with
`CertOpenSystemStoreW`, which asks for write access; a low-integrity
process may not write the user's stores, so under `--sandbox=low` every
HTTPS request failed ("Could not get root certificate store"). The recipe
opens them read-only (`CertOpenStore` with `CERT_STORE_READONLY_FLAG`);
an upstream report is drafted.

**cargo-c** ([`recipes/cargo-c.json`](../recipes/cargo-c.json)). cargo-c
0.10.25's `windows-gnu` release, with `cargo-cbuild` and `cargo-cinstall`:
33 MB, 16 MB compressed (see the decisions below for why not from source).

**librsvg.** librsvg 2.63.2 with FreeType 2.14.3 and libxml2 2.15.4 (the
module Text Editor had, with its `git describe` fix). Its crates come from
a pinned vendor step (320 MB tar, `5afe2e96…`), which a `.cargo/config.toml`
points cargo at. Meson builds the Rust code with cargo-c as a static
library and links `librsvg-2-2.dll` from it with zig. The recipe:

- passes `-Dtriplet=x86_64-pc-windows-gnu`: librsvg's Meson guesses
  `gnullvm` for a clang, and the Rust image has only `windows-gnu`;
- makes `nm` optional and drops the version script that needs it, which
  Windows builds don't use (`vflag = []`) but still generate;
- links the static library with `link_with` rather than `link_whole`: each
  crate's import libraries define the same import descriptors, and
  `--whole-archive` makes lld take all of them (duplicate
  `__IMPORT_DESCRIPTOR_kernel32`); without it, lld takes what the `.def`
  file's exports need;
- leaves out `rsvg-convert`, which cargo links with GNU ld and which
  crashes at startup (below);
- sets `PYTHONHASHSEED=0`: librsvg's script that asks rustc which system
  libraries to link dedupes them with a Python `set`, so the order of
  `Libs.private` in `librsvg-2.0.pc` followed Python's random hash seed,
  and a second store's SDK came out with another digest.

The GdkPixbuf loader is installed in `lib\gdk-pixbuf-2.0\2.10.0\loaders`,
and `gdk-pixbuf-query-loaders` (relocatable) writes `loaders.cache` with a
path relative to the SDK's root, which GdkPixbuf resolves against its own.

**The runtime** ([`recipes/gtk4.json`](../recipes/gtk4.json)) no longer
leaves out all of `lib`: it keeps `lib\gio\modules` (GLib finds GIO modules
next to its DLL's parent, so no variable is needed) and
`lib\gdk-pixbuf-2.0`, and leaves out `pkgconfig`, `cmake`, the libraries for
linking (`*.a`), the headers GLib and graphene keep in `lib`, and the new
tools (`xmllint`, `xmlcatalog`, `psl-make-dafsa`). It exports
`gtk4-widget-factory` again, with a "GTK Widget Factory" shortcut.

**Text Editor** ([`recipes/gnome-text-editor.json`](../recipes/gnome-text-editor.json))
drops its libxml2 module and pins the new SDK and runtime.

**Tests** ([`tests/gtk.sh`](../tests/gtk.sh)). The test app has two more
programs: [`soup.c`](../tests/gtk/soup.c), which prints GIO's TLS backend,
a PSL lookup, and the status and HTTP version (or the error) of each URL it
gets, and [`svg.c`](../tests/gtk/svg.c), which loads an image through
GdkPixbuf. The app now has the network permission.

**CI and publishing.** `scripts/published-recipes.txt` lists Perl and
cargo-c before GTK's SDK; the Reproduce workflow skips them with GTK.

### Code map

| File | Change |
|---|---|
| `recipes/perl.json` | new: Strawberry Perl |
| `recipes/cargo-c.json` | new: cargo-c's release |
| `recipes/gtk4-sdk.json`, `recipes/gtk4-sdk/openssl-unixspec.pm` | Perl, Rust and cargo-c in the SDK; OpenSSL, SQLite, nghttp2, libpsl, glib-networking, libsoup, FreeType, libxml2, librsvg |
| `recipes/gtk4.json` | keeps GIO modules and GdkPixbuf loaders; widget factory export and shortcut |
| `recipes/gnome-text-editor.json` | libxml2 from GTK; new pins |
| `tests/gtk.sh`, `tests/gtk/` | libsoup and SVG programs; HTTPS in each sandbox, PSL, SVG, runtime contents, widget factory |
| `scripts/published-recipes.txt`, `.github/workflows/reproduce.yml` | Perl and cargo-c published, skipped in CI |

No zigsaw code changed.

## Results

### Tests

- `tests/gtk.sh` (25 checks, 8 new, 95 s): an HTTPS GET of
  `https://ghcr.io/v2/` answers 401 over HTTP/2 with the OpenSSL backend,
  and `https://untrusted-root.badssl.com/` is refused ("Unacceptable TLS
  certificate"), under soft, low and AppContainer; libpsl's base domain of
  `www.example.co.uk`; an SVG loads through GdkPixbuf; the runtime has GIO's
  module and the SVG loader and no headers or libraries for linking; the
  widget factory runs for 15 s, with the windowless shim and its shortcut;
  the earlier checks, Text Editor's included, pass.
- By hand: the widget factory's window, screenshotted, shows its widgets
  and styles.
- Reproducibility: built again in a second, fresh store (zig's cache cold,
  Meson, CMake, zig, Rust and BusyBox pulled from ghcr.io), Perl
  (`4459f0a9…`), cargo-c (`e92c4386…`), GTK's SDK (`d0a03263…`), runtime
  (`8437fc86…`) and Text Editor (`70166928…`) have the same digests. The
  first try didn't: `librsvg-2.0.pc` listed its system libraries in another
  order (`PYTHONHASHSEED`, above).
- No zigsaw code changed, so the unit tests and the other suites weren't
  rerun.

### Measurements

| | |
|---|---|
| GTK SDK, fresh store with the downloads (cold zig cache, SDK images pulled) / warm store | 26.8 / 21 min (iteration 11: 18.2 / 15.5) |
| OpenSSL, BusyBox `make` / compiled with `xargs -P` | 16 min / 75 s |
| librsvg (Rust, Meson) | about 6 min |
| Text Editor and its four modules | 98 s |
| `org.gtk.Gtk4.Sdk` | 146 MB, 2,767 files, 51.4 MB gzip (was 107 MB, 37.4 MB) |
| `org.gtk.Gtk4` | 97 MB, 1,052 files, 43.2 MB gzip (was 73 MB, 33.2 MB) |
| `org.gnome.TextEditor`'s own layer | 4 MB, 30 files, 1.1 MB gzip (was 6 MB, 1.7 MB) |
| `org.perl.perl` | 161 MB, 7,124 files, 41 MB gzip |
| `com.github.lu-zero.cargo-c` | 33 MB, 2 files, 15.7 MB gzip |
| Runtime's new DLLs | librsvg 11.6 MB, OpenSSL GIO module 4.2, SVG loader 3.6, SQLite 1.6, libxml2 1.3, FreeType 0.8, libsoup 0.7 |

## Decisions made along the way

- **cargo-c's image is its upstream release** (the user's choice, deferring
  the fix below), not built from source. Built from source with
  `-D__MSVCRT_VERSION__=0x700` for its C code (libgit2 calls `swprintf_s`,
  which zig's UCRT headers inline into UCRT-only functions, and Rust links
  `msvcrt.dll`), it linked, but crashed at startup with 126 unbound imports.
  The other options were a prebuilt GNU assembler in the Rust image, an
  alias that drops arguments (zig's image and everything that pins it
  republished), or binutils from source.
- **librsvg without `rsvg-convert`**: it's a Rust program cargo links with
  GNU ld, and it crashed the same way (8 unbound imports). GTK needs the
  library and the loader; the loader, also linked by GNU ld, has all 1,224
  of its imports bound.
- **libxml2 moves into GTK's SDK and runtime**, as librsvg needs it, rather
  than staying in Text Editor and being built twice.
- **FreeType is built** although Windows' Pango doesn't use it: librsvg's
  Meson requires it.
- **libpsl without IDNA** (`runtime=no`): zig's MinGW headers have no
  `icu.h` for Windows' own ICU. libsoup gives it hostnames GLib has already
  converted to ASCII.
- **Probe recipes on the published SDK first**: OpenSSL, the libsoup stack
  and librsvg were each built on top of GTK's existing SDK image (minutes
  per try) before going into the SDK (21 minutes a build). Two SDK builds
  were still lost to a guard of mine on `loaders.cache` (CRLF, then a
  relative path I didn't expect).
- **This iteration's stores are on `D:`** (`D:\zs`): `C:` had 4 GB free.

## Bugs found

- **Rust programs linked by GNU ld can have unbound imports** (since
  iteration 5). rustc makes import libraries for `raw-dylib` imports
  (windows-sys 0.60 and later, through `windows-link`) with `dlltool`. The
  zig image's `dlltool` alias is llvm-dlltool, whose libraries GNU ld lays
  out wrongly when it links several: lookup entries land after another
  DLL's terminator, outside any import descriptor, so the loader never binds
  them, and the program crashes (access violation at the import's
  hint/name RVA) when it calls one. rustc's own source says as much: it uses
  GNU `dlltool` for windows-gnu because "the binutils linker ... cannot read
  the import libraries generated by LLVM". llvm-dlltool also ignores the
  `--temp-prefix` rustc gives each library. Checked with a script that
  counts lookup entries no descriptor reaches: ripgrep 0 of 135, bat 0 of
  285, cargo-c built here 126 of 488, `rsvg-convert` 8 of 1,891, librsvg's
  loader 0 of 1,224. Linking with lld instead doesn't work through zig:
  `zig ld.lld` is lld's ELF driver only, and MinGW's gcc runs `ld` itself,
  ignoring `-fuse-ld=lld`.
- **glib-networking can't read Windows' certificates at low integrity**
  (upstream; worked around in the recipe, report drafted).

## Findings

- Rust's MinGW bundle (`rust-mingw`) has GNU `dlltool` but no `as`, and
  GNU `dlltool` runs `as --64 -o x.o x.s`; zig's clang assembles that
  output, but rejects `--64`. So GNU `dlltool` would need only an `as` that
  drops `--64`.
- `--sandbox=low` fails on a store on a drive whose root grants users only
  Modify (no `WRITE_OWNER`), such as a fresh `D:`: setting a label needs it.
  Stores in the user profile are fine. Worked around here by granting the
  test folder full control.
- Python's string hashing is seeded at random per process, so build
  scripts that iterate over a `set` write things in a different order each
  run (librsvg's). The Meson image doesn't fix the seed; the module does.
- BusyBox-w32's `PATH` is `;`-separated; a `:`-joined prefix silently breaks
  the first entry.
- `gdk-pixbuf-query-loaders`, when relocatable, writes paths relative to its
  own root, with backslashes, and CRLF line endings.
- libsoup negotiates HTTP/2 with ghcr.io; glib-networking's OpenSSL module
  (4.2 MB, OpenSSL linked in) is most of the stack's size.
- The prebuilt cargo-c is UCRT-linked and has several import descriptors
  per DLL, as a correct GNU-dlltool or lld link has.

## Known gaps

- The GNU ld / llvm-dlltool defect above: any Rust program or DLL that
  cargo links can be affected; nothing checks for it.
- `rsvg-convert` isn't in GTK's images.
- libpsl has no IDNA library; internationalised domains rely on GLib's
  conversion.
- Proxies come only from the environment (`http_proxy` and the rest), not
  Windows' settings: no libproxy.
- `--sandbox=low` needs a store on a drive that lets you change owners.
- GTK's images, Perl, cargo-c, Text Editor and `tests/gtk.sh` aren't checked
  in CI.
- `tests/gtk.sh`'s HTTPS checks need the network, ghcr.io and badssl.com.

## Suggested for iteration 13

- The user republishes: Perl and cargo-c (new, to be made public), GTK's SDK
  and runtime (tags 4.24.1 overwritten) and Text Editor.
- Fix Rust links under GNU ld: an `as` that GNU `dlltool` can run (a GNU
  assembler, or an alias that drops `--64`), so rustc uses `rust-mingw`'s
  own `dlltool`; then cargo-c from source and `rsvg-convert` back, and a
  check for unbound imports in `tests/build.sh`.
- Let `--sandbox=low` work on a store whose drive withholds `WRITE_OWNER`
  (zigsaw could give the user full control of the store's root when it
  creates it).
- HarfBuzz with DirectWrite, spell checking (enchant, hunspell), shortcut
  icons, file associations.
- GTK back in CI, perhaps as its own job.
