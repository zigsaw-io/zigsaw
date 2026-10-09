# Iteration 14: text, spelling, and GTK's SDK as a workbench

Concluded 2026-10-09.

## Outcome

- **Text is shaped by HarfBuzz with DirectWrite.** GTK's SDK built HarfBuzz
  without it, so a font file an app added to Pango, as GtkSourceView adds
  its own, made Pango warn that it would shape badly. HarfBuzz now has
  DirectWrite and GDI, and Pango uses them for such fonts.
- **Spell checking.** GTK's SDK and runtime have **enchant 2.8** with two
  providers: Windows' own spell checker (WinSpell, new in enchant 2.8.19),
  for the languages Windows has, and **hunspell 1.7** with an en_US
  dictionary, everywhere the same. GNOME Text Editor's libspelling uses it,
  in all three sandboxes.
- **GTK's SDK builds programs without a recipe.** Its toolchain, zig, Meson
  and BusyBox, became its **runtimes**: one pull of the SDK brings them, and
  the SDK exports `cc`, `c++`, `ar`, `rc`, `pkg-config`, `meson`, `ninja`,
  `sh`, `make` and GLib's and GTK's tools. `cc hello.c $(pkg-config --cflags
  --libs gtk4)` and `meson setup` work from your own shell, and the program
  runs on GTK's runtime with `zigsaw run --command=<its path>
  org.gtk.Gtk4`. The runtime exports `gio`, `pango-view` and `pango-list`.

Two zigsaw changes made the last possible:

- **Aliases work in runs**, not only in builds: an app's own and its
  runtimes', from the store's `aliases\<id>\`, first on PATH. Meson run
  from GTK's SDK finds zig's `cc` that way.
- **SDKs and image sources may have runtimes.** An SDK's runtimes join the
  builds that use it, right after it; recipes that build with GTK's SDK no
  longer list zig, Meson and BusyBox.

And one defect from iteration 9 is fixed: **under `--sandbox=low`, BusyBox's
`sh -c` dropped its last command** (no output, exit code 0), because the
shell couldn't see zigsaw and took itself for an orphan.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-14-zippy-gem.md`):

- Scope, the user's choice: text rendering and spelling, plus "pkg-config,
  gio, pangocairo", which the user clarified as **usable commands** and
  **builds outside a recipe**. Not this time: `low` as the default, GTK in
  CI, shortcut icons, file associations.
- Spelling: **both WinSpell and hunspell** (with a pinned dictionary), over
  either alone; enchant in **GTK's SDK and runtime**, over Text Editor's
  image.
- Outside a recipe: the user's direction was "the SDK exports everything
  needed"; of two ways, they chose **zig, Meson and BusyBox as the SDK's
  runtimes** (shared layers; zigsaw changes) over copying them into its
  layer (no zigsaw changes, 0.5 GB of zig twice).
- Probes first, on the published SDK: hunspell and enchant with their
  `configure`, WinSpell in the sandboxes, HarfBuzz with DirectWrite.

Planning also confirmed that iteration 13's images were republished
(ghcr.io had GTK's SDK `c5756c48` and runtime `f7df3f77`) and that its
Reproduce run was green (45 minutes).

## What was built

**Aliases in runs** ([`src/aliases.zig`](../src/aliases.zig),
[`src/run.zig`](../src/run.zig), [`src/oci.zig`](../src/oci.zig)). A
runtime in an app's config may now carry the runtime's `aliases`, copied
at build time, and left out of the JSON when it has none, so no other
image's config changes. Before each run, zigsaw makes the store's
`aliases\<app id>\` hold the shims of the app's aliases, then its
runtimes', the first of a name winning, writing only what changed (a run
with nothing new writes nothing, so Defender has nothing to scan), and
puts it first on the run's PATH with `BB_OVERRIDE_APPLETS`. It's in the
store rather than the app's data directory, which sandboxed runs can write,
and by app rather than by version, so the paths Meson writes into
`build.ninja` stay valid across updates. AppContainer runs get read access
to it. `rm` and `prune` delete it. Alias arguments can't use `${data}` or
`${cache}`, so normal and `--ephemeral` runs share one directory. Builds
write `B:\bin` through the same module.

**SDKs with runtimes** ([`src/builder.zig`](../src/builder.zig),
[`src/deps.zig`](../src/deps.zig)). Only runtimes still refuse images
that have runtimes. An SDK's runtimes come into the build right after it,
from its own config and layers; a tool image named twice is used once, and
two versions of one app in a build fail it. An SDK's own variables win
over its runtimes', as in its runs. An image source takes only the image's
own layer, as before. Builds also check that an image's own aliases run.

**Low integrity and BusyBox's last command** ([`src/acl.zig`](../src/acl.zig)).
busybox-w32 runs the last command of `sh -c` as an `exec`, which waits for
the command unless `getppid()` is 1. Its `getppid()` reads the parent's
start time to tell a parent from a reused PID, and a low-integrity process
can't open a medium-integrity one even to query it (the process label has
NO_READ_UP); so the shell exited at once, and zigsaw's job then ended the
command. Low runs now give zigsaw's own process a label without NO_READ_UP
(still NO_WRITE_UP). An AppContainer doesn't see processes outside it at
all, so it keeps the problem (known gaps). A report for busybox-w32 is
drafted.

**GTK's SDK** ([`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json)):

- zig, Meson and BusyBox as runtimes; CMake, Perl, Rust and cargo-c stay
  build-only.
- `env`: `PKG_CONFIG_PATH` to its own `.pc` files and `RC=rc /:auto-includes
  gnu`, for its runs; the `cwd` permission; the exports above.
- HarfBuzz with `-Ddirectwrite=enabled -Dgdi=enabled`, which Pango picks up
  (`USE_HB_DWRITE`).
- hunspell 1.7.5 and enchant 2.8.21, with their release's `configure` and
  BusyBox's make, and the en_US dictionary from LibreOffice's dictionaries
  (pinned commit). enchant's ordering file puts WinSpell first.
- Each import library also as `<name>.lib` (40 of them, 5.3 MB): zig's cc
  finds `-lfoo` as `foo.lib` but not as `libfoo.dll.a`.

**GTK's runtime** ([`recipes/gtk4.json`](../recipes/gtk4.json)) exports
`gio`, `pango-view` and `pango-list`, keeps enchant's providers and the
dictionary, and leaves out `.la` and `.lib` files.

**Text Editor** ([`recipes/gnome-text-editor.json`](../recipes/gnome-text-editor.json)):
libspelling with enchant. libspelling names dictionaries' languages with
ICU, which the SDK doesn't have; Windows has (`icu.dll`, Windows 10 1903 and
later), zig links it (`-licu`), and [a header](../recipes/gnome-text-editor/icu-uloc.h)
declares the two functions libspelling calls. Its `sdk` is GTK's SDK and
CMake.

### Code map

| File | Change |
|---|---|
| `src/aliases.zig` (new) | resolving aliases, writing them for builds, syncing them for runs |
| `src/run.zig` | alias directory first on PATH, `BB_OVERRIDE_APPLETS`, AppContainer grant; `--command` hint |
| `src/oci.zig`, `src/deps.zig` | `aliases` on runtimes; alias checks shared, no `${data}`/`${cache}` in arguments; SDKs and sources may have runtimes |
| `src/builder.zig` | tools: an SDK's runtimes, dedupe, version clash, variable order; alias check |
| `src/Store.zig`, `src/main.zig`, `src/prune.zig` | `aliases\<id>\` and its lock; `rm` and `prune` |
| `src/acl.zig`, `src/win32.zig` | zigsaw's own label for low runs; ACL buffers DWORD-aligned |
| `src/Sidecar.zig` | comments |
| `recipes/gtk4-sdk.json`, `recipes/gtk4-sdk/*` | runtimes, exports, HarfBuzz, hunspell, enchant, dictionary, `.lib` copies; autotools helpers |
| `recipes/gtk4.json` | exports, cleanup, pin |
| `recipes/gnome-text-editor.json`, `recipes/gnome-text-editor/icu-uloc.h` | libspelling with enchant; pins |
| `tests/build.sh` | aliases in runs, SDKs with runtimes |
| `tests/sandbox.sh` | `sh -c`'s last command at low |
| `tests/gtk.sh`, `tests/gtk/*` | fonts, Pango's tools, GIO, spelling, builds without a recipe |
| `README.md` | aliases, runtimes, SDKs, GTK, known gaps |

## Results

### Tests

- Unit tests: 75 pass (69 before), with new cases for runtimes' aliases in
  configs and their checks, resolving and syncing alias shims, the order of
  their providers, a build's tools (each image once, one version of each
  app) and the order of their variables.
- `tests/build.sh` (106 checks, 719 s seeded): a new section, BusyBox
  fixtures only, for aliases in runs: the app's own over its runtime's,
  `drop`, over BusyBox's applets, exit codes, `--command`, the runtime's
  variables, no rewrites on a second run, low, AppContainer and
  `--ephemeral` runs, removal by a version without aliases, by `rm` and by
  `prune`; and for an SDK with a runtime: a build gets its aliases and
  variables, naming the runtime too uses it once, another version fails, an
  image source takes only the SDK's files.
- `tests/sandbox.sh` (35 checks, 2 new): at low, sh sees zigsaw as its
  parent, and `sh -c`'s last command runs to its end with its exit code.
  Three runs in a row passed after the ACL alignment fix.
- `tests/gtk.sh` (all pass; 17 new checks): Pango adds a font file without
  warning and pangocairo draws with it (soft and low with
  `G_DEBUG=fatal-warnings`; under AppContainer, DirectWrite's own warning
  about user fonts is expected); the runtime's `pango-view`, `pango-list`
  and `gio`; enchant with WinSpell and hunspell in all three sandboxes;
  WinSpell first; no dictionary for a language neither has; `cc` and
  `pkg-config` from the store's shims build GTK's hello, and the SDK's
  `meson` sets up and compiles the test project, whose programs run on the
  runtime. The same font program, run on the runtime of iteration 13,
  prints Pango's warning.
- `tests/shims.sh`, `tests/batch.sh`, `tests/ctrlc.sh`: pass.
- `tests/matrix.sh`: as intended in all three columns (only the known
  AppContainer gaps fail).
- `tests/published.sh` for BusyBox, MinGit, Node, Prettier, Python, zig,
  SQLite, CMake, zstd and Meson: all have the digests published on ghcr.io,
  so zigsaw's changes don't change other images.
- Reproducibility: GTK's SDK `1ea0edab`, runtime `5299a617` and Text Editor
  `94f4b773`, built in `D:\zs\a` and `D:\zs\b`, are the same.
- Text Editor's executable binds all its 1,050 imports; libspelling's DLL
  imports `libenchant-2-2.dll` and Windows' `icu.dll`. A screenshot of its
  underlined words wasn't possible (the screen captured black).

### Measurements

| | |
|---|---|
| GTK SDK, warm store | 26.5 min (iteration 13: 22–23) |
| `org.gtk.Gtk4.Sdk`'s own layer | 163 MB, 57.8 MB gzip (was 156 MB, 56.3 MB) |
| pulling the SDK | also brings zig (87.9 MB gzip), Meson (13.9 MB) and BusyBox (0.4 MB) |
| `org.gtk.Gtk4` | 97 MB, 43.7 MB gzip (was 96 MB, 42.9 MB) |
| hunspell + enchant modules | about 3 min, mostly `configure` under BusyBox |
| Text Editor | 3.9 MB own layer |

## Decisions made along the way

- **hunspell and enchant with their own `configure`**, the plan's first
  choice, over Meson files of our own: it took eight workarounds, all in
  the recipe and two small scripts, and builds upstream's release as is.
- **zig's import libraries as `<name>.lib` in the SDK**, so that `-lgtk-4`
  works for `cc` and libtool; Meson links by path and didn't need it.
- **libspelling uses Windows' ICU**, rather than ICU built into GTK's SDK
  (a large library, for two functions that name languages).
- **The low-integrity fix changes zigsaw's process, not BusyBox**, which is
  a prebuilt binary here; the busybox-w32 report is the real fix.
- **AppContainer keeps the BusyBox problem** (no workaround found that
  doesn't change the process tree).

## Bugs found

- busybox-w32: `sh -c` drops its last command when it can't query its
  parent (low integrity, AppContainer). Worked around for low; report
  drafted.
- zigsaw: ACL buffers for labels were aligned to 2 bytes; the kernel wants
  4, and refused them now and then (error 998). Found by the new label on
  zigsaw's process; the file labels had the same code.

## Findings

- zig's `cc` looks for `-lfoo` as `foo.dll`, `foo.lib` or `libfoo.a`, not
  `libfoo.dll.a`, the name MinGW import libraries have.
- BusyBox's make (pdpmake) remakes a target whose prerequisite has the same
  modification time, where GNU make doesn't; release tarballs give
  generated autotools files the same time as their sources.
- Autoconf finds programs as files on PATH, so BusyBox's applets and
  `.exe` aliases need naming (`SED=sed`, `PKG_CONFIG=pkg-config`); libtool
  on MinGW needs `$LD --help` to mention auto-import, `nm` for export
  regexes (a `.def` file avoids it), and `objdump` for its library checks.
- enchant falls back from a territory to the language: `en_ZZ` gets
  English.
- Pango doesn't fall back to another font for a script its font lacks
  (Devanagari in Segoe UI), with or without HarfBuzz's DirectWrite.
- `tests/gtk.sh`'s `gtk4-query-settings` check failed once with no output,
  and passed six times by hand.

## Known gaps

- Under `--sandbox=appcontainer`, BusyBox's `sh -c` still drops its last
  command.
- An update while an app runs switches its later alias calls to the new
  version's tools; a Meson build directory set up with the SDK's `meson`
  needs setting up again after the SDK is updated.
- Text Editor's spelling covers Windows' languages and English (US) only;
  no translations or help.
- GTK's images and Text Editor aren't checked in CI.
- The gaps of earlier iterations otherwise remain (README's known gaps).

## Suggested for iteration 15

- The user republishes GTK's SDK, runtime and Text Editor.
- File the busybox-w32 report; then `low` as the default, with a fallback
  for a writable cwd that's the user profile or a drive's root.
- GTK back in CI, perhaps as its own job.
- Shortcut icons, file associations; more hunspell dictionaries, or a way
  to add them.
