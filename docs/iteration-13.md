# Iteration 13: Rust links that load, and low integrity on any drive

Concluded 2026-10-08.

## Outcome

Iteration 12 left two defects, and both are fixed:

- **Rust programs that GNU ld links have all their imports bound.** Since
  iteration 5, rustc made the import libraries for `raw-dylib` imports
  (windows-sys 0.60 and later) with zig's `dlltool` alias, llvm-dlltool,
  whose libraries GNU ld lays out wrongly: cargo-c built from source had
  126 imports the loader never bound, and `rsvg-convert` 8, and both
  crashed. Rust's image now gives builds the GNU `dlltool` that Rust ships,
  and zig's image gives it the assembler it needs, as an alias: `zig cc`
  in assembler mode, without the `--64` it doesn't take. Aliases can now
  **drop** arguments for that.
- **`--sandbox=low` works on a drive that gives users only Modify**, such
  as a fresh `D:`. Setting an integrity label needs the right to change a
  path's owner, which such a drive withholds; zigsaw now grants it to you
  for the change and puts the permissions back.

With the first fixed, **cargo-c is built from source** again, and **GTK's
SDK has `rsvg-convert`**. A new check, **`zigsaw-imports`**
(`zig build imports`), counts the imports the loader wouldn't bind;
`tests/build.sh`, `tests/published.sh` and `tests/gtk.sh` run it.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-13-wobbly-glacier.md`):

- Scope, the user's choice: fix Rust under GNU ld, and `--sandbox=low` on
  drives that withhold `WRITE_OWNER`. Not this time: `low` as the default
  (though CI's matrix shows the low column all `ok` on Windows Server
  2025), GTK in CI, HarfBuzz with DirectWrite, spell checking, shortcut
  icons, file associations.
- The assembler: **zig's cc as `as`**, through an alias that drops
  arguments, over a prebuilt GNU `as` from MSYS2 in Rust's image, or GNU
  binutils built from source.
- A probe first, as a gate: GNU `dlltool` with zig's clang assembling its
  output must leave no import unbound and reproduce, or back to the user.

Planning also confirmed that iteration 12's images were published (ghcr.io
had Perl `4459f0a9`, cargo-c `e92c4386`, GTK's SDK `d0a03263`, runtime
`8437fc86` and Text Editor `70166928`) and that its Reproduce run was green
(44 minutes).

## What was built

**Aliases that drop arguments** ([`src/oci.zig`](../src/oci.zig),
[`src/Sidecar.zig`](../src/Sidecar.zig), [`src/shim.zig`](../src/shim.zig)).
An alias may have `drop`, a list of the caller's arguments to leave out,
by value. The alias's `.shim` file gets a `drop = …` line for each, and the
shim, which otherwise passes the caller's arguments on exactly as typed,
splits them as the C runtime does (`std.process.Args.Iterator.Windows`),
leaves out those that match, and quotes the rest again. `drop` is refused
on exports and on values with spaces at either end or line breaks, and is
left out of configs without it, so other images keep their digests.

**zig's and Rust's images** ([`recipes/zig.json`](../recipes/zig.json),
[`recipes/rust.json`](../recipes/rust.json)):

- zig's `dlltool` alias is gone; its new `as` alias runs
  `zig cc -target x86_64-windows-gnu -c -x assembler`, dropping `--64`.
  GNU `dlltool` runs `as --64 -o x.o x.s` for each import library's head,
  tail and stubs.
- Rust's image aliases `dlltool` to the GNU `dlltool.exe` in `rust-mingw`'s
  `self-contained` directory, which stays off PATH otherwise (it also has
  `gcc` and `ld`), with `--as as`. Without it, `dlltool` looks for `as` in
  its own directory first, and when its path has only backslashes, as the
  shim gives it, it takes that path without checking that the file exists,
  and fails with `CreateProcess`. (The probe passed rustc
  `-C dlltool=<path>` with forward slashes, where the check happens.)
- Rust's image sets `CARGO_PROFILE_RELEASE_STRIP=symbols` (below).
- Both images' layers are unchanged; only their configs are new.

**The import checker** ([`tests/imports.zig`](../tests/imports.zig), built
by `zig build imports` as `zig-out\test\zigsaw-imports.exe`). For each PE
file it walks every import descriptor's list in the import address table
and counts the non-empty slots no list reaches: the loader leaves those as
the linker wrote them, and a call through one crashes. It agrees with the
objdump script of iteration 12 on every file tried, and finds the 8
unbound imports in iteration 12's `rsvg-convert`. Files that aren't PE
files are skipped (GTK's SDK has an import library named
`lib\libpng.dll`).

- [`tests/build.sh`](../tests/build.sh): the Rust fixture builds with GNU
  `dlltool` and zig's `as`, and its program has all its imports bound.
- [`tests/published.sh`](../tests/published.sh): every image whose recipe
  uses Rust's has all imports bound in its programs and DLLs (ripgrep and
  bat in CI; cargo-c and GTK's locally).
- [`tests/gtk.sh`](../tests/gtk.sh): the SDK's `rsvg-convert` has all its
  imports bound and makes a PNG of an SVG.

**cargo-c from source** ([`recipes/cargo-c.json`](../recipes/cargo-c.json)).
cargo-c 0.10.25 from its crate, with a pinned vendor step (`f34cfd29…`);
only `cargo-cbuild` and `cargo-cinstall` are built. libgit2's C code is
compiled with `-D__MSVCRT_VERSION__=0x700`: zig's headers default to UCRT,
whose `swprintf_s` they inline into functions only UCRT has, and Rust links
`msvcrt.dll`.

**`rsvg-convert` in GTK's SDK** ([`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json));
the runtime leaves it out, as it does `xmllint`
([`recipes/gtk4.json`](../recipes/gtk4.json)).

**Labels without `WRITE_OWNER`** ([`src/acl.zig`](../src/acl.zig)). When
setting a label fails with access denied, `writeLabel` adds an
inheritable allow ACE giving the current user `WRITE_OWNER`, sets the label
again, and writes back the DACL it read before. That needs `WRITE_DAC`,
which a path's owner has. The label stays when the ACE goes, so nothing new
is recorded: `zigsaw rm` unlabels the same way. Data directories and host
grants both go through it, so existing stores on such drives work too. A
path the user may not change the permissions of fails with a message
saying so.

### Code map

| File | Change |
|---|---|
| `src/oci.zig`, `src/recipe.zig` | `drop` on aliases, validated |
| `src/Sidecar.zig`, `src/builder.zig`, `src/shim.zig` | `drop` lines in alias sidecars; the shim splits, filters and requotes |
| `src/acl.zig`, `src/win32.zig` | labels through a temporary `WRITE_OWNER` grant |
| `tests/imports.zig`, `build.zig` | the import checker |
| `recipes/zig.json`, `recipes/rust.json` | `as` instead of `dlltool` in zig's; GNU `dlltool` in Rust's |
| `recipes/cargo-c.json` | from source |
| `recipes/gtk4-sdk.json`, `recipes/gtk4.json` | `rsvg-convert` in the SDK, not the runtime |
| other recipes | new pins |
| `tests/build.sh`, `tests/published.sh`, `tests/gtk.sh`, `tests/sandbox.sh` | import checks, `rsvg-convert`, a directory that withholds `WRITE_OWNER` |
| `README.md` | aliases' `drop`, Rust's `dlltool`, known gaps |

## Results

### Tests

- Unit tests: 69 pass, with new cases for `drop` in sidecars, the shim's
  split and requote, and recipes refusing `drop` on exports or with
  untrimmed values.
- `tests/sandbox.sh` (33 checks, 3 new): a `--sandbox=low` run writes a
  directory that gives its owner only Modify (the ACL D:'s root gives),
  labels it, and leaves its ACL as it was; `zigsaw rm` unlabels it and
  leaves the ACL as it was again. icacls is refused the same label there,
  so the fixture does withhold `WRITE_OWNER`.
- `tests/build.sh` (84 checks, 695 s seeded): the Rust fixture builds with
  GNU `dlltool` and zig's `as`, runs, has all 193 imports bound, and
  rebuilds to the same image.
- `tests/gtk.sh` (26 checks, 1 new): `rsvg-convert` binds all its imports
  and makes a PNG; the rest as before.
- `tests/matrix.sh`: as intended (only the known AppContainer gaps fail),
  low column included.
- `tests/published.sh`, for busybox, zig, Rust, ripgrep and bat: the new
  import check passes on the published ripgrep and bat; the four changed
  images differ from ghcr.io, as they will until republished. Run on the
  deployment with iteration 12's `rsvg-convert`, the check fails.
- `zigsaw-imports` on every program and DLL of the rebuilt Rust images:
  ripgrep 135 imports, bat 285, `cargo-cbuild` and `cargo-cinstall` 488
  each, `rsvg-convert` 1,891, librsvg's DLL 1,919, its loader 1,224, and
  GTK's other 80 files: none unbound.
- Reproducibility: the eleven images, built in two stores (`D:\zs\a`,
  `D:\zs\b`), have the same digests: zig `0379659d`, SQLite `18390935`,
  Rust `e7e97064`, ripgrep `168eb109`, bat `1eaeaa55`, zstd `5714b0d2`,
  Meson `9f166093`, cargo-c `5c3ab826`, GTK's SDK `c5756c48`, runtime
  `f7df3f77`, Text Editor `81c0605f`. The first try didn't: cargo-c
  (Decisions, below).
- By hand: ripgrep, bat and cargo-c print their versions;
  `cargo-cbuild --help` runs, where iteration 12's build crashed.

### Measurements

| | |
|---|---|
| cargo-c from source (vendored crates cached) | about 6 min |
| `com.github.lu-zero.cargo-c` | 81 MB, 32.4 MB gzip (upstream release: 33 MB, 15.7 MB) |
| GTK SDK, warm store | 22–23 min (iteration 12: 21) |
| `org.gtk.Gtk4.Sdk` | 156 MB, 56.3 MB gzip (was 146 MB, 51.4 MB) |
| `org.gtk.Gtk4` | 96 MB, 42.9 MB gzip (was 97 MB, 43.2 MB) |
| `rsvg-convert.exe` | 12.4 MB |
| zig's and Rust's layers | unchanged (88 MB and 179 MB gzip), so republishing them pushes configs and manifests only |
| Layers that change | ripgrep, bat, cargo-c, GTK's SDK and runtime; SQLite, zstd, Meson and Text Editor keep theirs |

## Decisions made along the way

- **Release builds strip symbols, set in Rust's image** (the user's
  choice, over setting it in cargo-c's and librsvg's recipes). The second
  store's cargo-c had another digest: GNU `dlltool` names the symbols of
  each import library after its output path (`_head_B__src_…_rustcXXXXXX_
  kernel32_dll_imports_lib`), which is in rustc's temporary directory, with
  a random name, and cargo-c's release profile keeps the symbol table. Every
  differing byte was in the symbol table, or the PE checksum over it.
  ripgrep, bat and the test fixture strip already; `rsvg-convert` and
  librsvg's GdkPixbuf loader didn't. llvm-dlltool named them after the DLL.
  `CARGO_PROFILE_RELEASE_STRIP=symbols` in the image's environment, like
  zig's `LDFLAGS=-s`, makes every Rust recipe's release build leave them
  out.
- **Rust's image passes `--as as` to `dlltool`** rather than zigsaw giving
  alias programs a forward-slash path or a bare name as `argv[0]`, which
  would change what every aliased program sees.
- **The ACL is written back as it was**, rather than the `WRITE_OWNER`
  ACE kept until `rm`: nothing to record, and the host's permissions are
  left as found. It costs two more walks of the tree on such drives, once.
- **cargo-c builds only the two programs librsvg needs**, as the published
  release image kept only those.
- **`rsvg-convert` stays out of GTK's runtime**, like the SDK's other
  command-line tools (`xmllint`, `psl-make-dafsa`).

## Bugs found

- GNU `dlltool` trusts a backslash-only path for its assembler without
  checking it exists (above), in binutils' `look_for_prog`.
- Caught before it shipped: with GNU `dlltool`, Rust programs that keep
  their symbol table didn't reproduce (above).

## Findings

- With GNU `dlltool`, ripgrep's and bat's executables change (their import
  layout); SQLite, zstd, Meson and Text Editor only get new configs, and
  zig's and Rust's layers are as before.
- cargo-c built here is two and a half times the size of its release:
  each program is 40 MB, msvcrt-linked, with cargo inside it.
- `tests/matrix.sh`'s "job ends background children" fails in every column
  while a build runs BusyBox elsewhere on the machine (it looks for any
  `busybox.exe`), as `tests/store.sh` was known to.
- `rsvg-convert` reads only the first two bytes of a file given as its
  standard input, run by zigsaw or not; a pipe works.
- An elevated administrator on CI can label paths that withhold
  `WRITE_OWNER` anyway, so `tests/sandbox.sh` skips that check there.

## Known gaps

- `--sandbox=low` still isn't the default.
- A writable grant of a path you neither own nor may change the
  permissions of fails under `--sandbox=low`.
- GTK's images, Perl, cargo-c, Text Editor and `tests/gtk.sh` aren't checked
  in CI.
- The gaps of earlier iterations otherwise remain (README's known gaps).

## Suggested for iteration 14

- The user republishes the 11 images: zig, SQLite, Rust, ripgrep, bat,
  zstd, Meson, cargo-c, GTK's SDK and runtime, Text Editor.
- Make `--sandbox=low` the default, with a fallback when a writable cwd is
  the user profile or a drive's root.
- GTK back in CI, perhaps as its own job.
- HarfBuzz with DirectWrite, spell checking, shortcut icons, file
  associations.
