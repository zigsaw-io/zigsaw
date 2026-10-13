# Iteration 16: files that open apps, and GTK with MSVC

Concluded 2026-10-13.

## Outcome

- **Files open apps.** A recipe declares the kinds of file its app opens
  (`"associations"`), and installing the app offers it for them in
  Explorer's "Open with", with its name and icon, for the user alone and
  without an administrator. Rnote is offered for `.rnote` and `.xopp`, Text
  Editor for `.txt`, `.md` and `.log`. zigsaw never makes itself the
  default: Windows asks the user.
- **`zigsaw run --file=<path>`** hands an app one file, whatever its
  sandbox: under `low` that file alone is labelled low integrity, under
  `appcontainer` the app's capability is granted that file alone. A file
  opened from Explorer comes this way.
- **Icons.** GTK's demos' and Text Editor's shortcuts show their icons,
  made from their SVGs by a script in the recipes.
- **The taskbar.** An app started from its shortcut counts as started from
  it, through the shim and zigsaw, as one Explorer starts does.
  Whether a pinned window then pins the shortcut takes a pin by hand,
  which wasn't done from here.
- **A crash fixed in GTK.** GTK 4.24.1's input method for Windows read freed
  memory after a text widget that had the focus was removed; Text Editor
  crashed opening a file over an empty draft. Patched in the SDK.
- **Rnote saves a file it was only given**, by a patch that writes in place
  when it can't make its temporary file.
- **GTK built with MSVC**, as an experiment
  (`recipes/gtk4-msvc.json`, not published): GLib through GTK 4.24.1 and
  libadwaita build with the machine's Visual Studio in nine minutes, the
  demos run in all three sandboxes, and the image comes out the same from
  two stores. Against zig's build of the same modules it builds faster
  (8.9 against 14.4 minutes), is a little smaller, and starts as fast; it
  has no translations, SVG loader, HTTP or spell checking, and only this
  machine's Visual Studio rebuilds it.

## Starting decisions

From the planning session (plan file `let-s-plan-iteration-16-dreamy-church.md`).
Iteration 15's images were on ghcr.io with its digests, and its Reproduce
run green (26 minutes).

- Scope, the user's picks: **desktop integration** (file associations,
  icons for apps whose icons are SVGs, the taskbar) and, the user's own
  addition, **"attempt alternative GTK build using MSVC"**.
- A file opened through an association is **granted as that one file**, not
  its folder and not nothing (the user's choice of three).
- MSVC: **GLib through GTK and libadwaita, with the demos, as findings**;
  not Text Editor on it, nor parity with the zig SDK.

Decided along the way, with the user:

- **Patch Rnote** to save in place, over leaving it a known gap or granting
  such apps the folder: Rnote saves only by temporary file and rename.
- **Patch GTK in the SDK** for the input method's crash, found while
  testing Text Editor with a file, over a known gap or turning Windows'
  input methods off for Text Editor. It cost the SDK rebuild the plan had
  avoided.

## What was built

### `--file` ([`src/run.zig`](../src/run.zig), [`src/main.zig`](../src/main.zig))

The option resolves the path against the caller's directory, checks it's a
file, adds it to the run's grants and to the end of the app's arguments. It
needed no new sandbox code: a probe showed that a file given where a
directory was expected already works, for a low label (Windows drops the
inheritance flags on a file) and for an AppContainer grant. `zigsaw rm`
undoes both from the grants it recorded. `override` refuses it.

### File associations

- [`src/associations.zig`](../src/associations.zig) (new), on the pattern
  of `shortcuts.zig`: under `HKCU\Software\Classes`, a key
  `Zigsaw.<app id>.<extension>` with the description, `DefaultIcon`,
  `shell\open\command` and `Application` (`ApplicationName`,
  `ApplicationIcon`), and its name as a value of the extension's
  `OpenWithProgids`. The key names its store and app; zigsaw removes only
  keys that name its store, and an extension's own keys only once nothing
  is left in them.
- **Open shims**: `<root>\open\<app id>\<export>.exe`, the same shim with
  `files = true` in its `.shim` file, which turns each of its arguments
  into `--file=<argument>` ([`src/shim.zig`](../src/shim.zig),
  [`src/Sidecar.zig`](../src/Sidecar.zig)). The export's shim in `bin` is
  as before.
- Config and recipe field `associations`, absent unless used, so no
  existing image's digest changes ([`src/oci.zig`](../src/oci.zig),
  [`src/recipe.zig`](../src/recipe.zig)); the builder checks icons as it
  does shortcuts'.
- Only the default store registers; `ZIGSAW_CLASSES_KEY` names another key
  under HKCU, for tests.
- `zigsaw list` shows `(opens .rnote, .xopp)`; `rm` removes it all; `prune`
  clears the open shims of apps that are gone.

### The taskbar

[`src/shim.zig`](../src/shim.zig) reads its own `STARTUPINFO`: when
Explorer started it from a shortcut (`STARTF_TITLEISLINKNAME`), it hands
the shortcut's path to zigsaw in `ZIGSAW_SHORTCUT`, and
[`src/process.zig`](../src/process.zig) starts the app with the same flag
and title. Shortcuts get no AppUserModelID: a window has the one its
process sets, which zigsaw can't do from outside the app.

### Recipes

- [`recipes/gtk4-sdk/svg2ico.sh`](../recipes/gtk4-sdk/svg2ico.sh) (new):
  an `.ico` of an SVG, the SDK's `rsvg-convert` drawing it at 16, 24, 32,
  48, 64 and 256 pixels, the PNGs packed with BusyBox's `printf`.
- [`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json): GTK with
  [`gtk-ime-filter.patch`](../recipes/gtk4-sdk/gtk-ime-filter.patch).
- [`recipes/gtk4.json`](../recipes/gtk4.json): the runtime builds now,
  with the SDK, to make its three demos' icons; its shortcuts name them.
- [`recipes/gnome-text-editor.json`](../recipes/gnome-text-editor.json):
  its icon, and `.txt`, `.md`, `.log`.
- [`recipes/rnote.json`](../recipes/rnote.json): `.rnote`, `.xopp`, and
  [`save-in-place.patch`](../recipes/rnote/save-in-place.patch).
- [`recipes/gtk4-msvc.json`](../recipes/gtk4-msvc.json) (new): see below.

### GTK with MSVC

[`recipes/gtk4-msvc.json`](../recipes/gtk4-msvc.json), `org.gtk.Gtk4.Msvc`:
`"host": ["msvc"]`, with Meson's, CMake's and BusyBox's images as SDKs, and
the zig recipe's modules from zlib to libadwaita at the same versions and
pins, GTK's input method patch and Pango's among them. One image, with the
demos; no SDK and runtime split. zigsaw itself needed no change.

A probe first (zlib, pcre2, libffi, GLib) showed Meson and CMake picking
`cl` 19.51, `link` and the Windows SDK's `rc` with nothing set. The full
recipe then took four builds:

1. GLib found no `intl`: proxy-libintl, built as a static library, is
   `libintl.a` to Meson, and MSVC's linker looks for `intl.lib`; its header
   also declares the functions imported. Built as a DLL instead.
2. cairo found no libpng: libpng's CMake build installs its pkg-config
   file for MinGW and Unix only. The recipe writes one.
3. libadwaita's demo, made a GUI program as in the zig recipe, didn't link:
   MSVC wants `WinMain`, or `/entry:mainCRTStartup` for a `main`.
4. Built. The widget factory aborts for want of an SVG loader, as the zig
   build's did before librsvg (iteration 11), so it isn't exported.

What the zig recipe has and this one doesn't need: the `crt-noexport`
object and its `LDFLAGS`, the WinRT headers from mingw-w64, `RC` and
`CMAKE_RC_FLAGS` with `/:auto-includes gnu`, `/:output-format coff`,
`-Wno-error=date-time`, `CROARING_COMPILER_SUPPORTS_AVX512=0`, `-s` for
static libraries, the `.lib` copies of import libraries, and gettext's
image. What it needs that zig's doesn't: `CL` and `LINK` for `/Brepro` and
the prefix's directories, proxy-libintl, libpng's `.pc`, the demo's entry
point, and the Visual C++ runtime's DLLs copied from
`%VCToolsRedistDir%`.

### Tests

- [`tests/sandbox.sh`](../tests/sandbox.sh) (48 checks, 8 s): `--file`
  under each sandbox reads and rewrites the file; under `low` and
  `appcontainer` the file next to it stays out of reach, and only the file
  is labelled; a relative path; a missing file and a directory are
  refused; `rm` takes the label and the grant away.
- [`tests/shims.sh`](../tests/shims.sh) (54 checks, 59 s), with a scratch
  registry key: the fixture's `.zigsawtest` is registered; the registered
  command, with a path with spaces for `%1`, has the app rewrite that file,
  under `low` too; an update registers what's declared then; someone else's
  entry survives `rm`; a store other than the default registers nothing.
  The fixture started from its shortcut finds the shortcut's path in its
  own `STARTUPINFO`, and none when a command line started it.
- [`tests/gtk.sh`](../tests/gtk.sh) (73 checks, 352 s on a store with the
  images): the icons are `.ico` files
  of six PNGs; the apps' extensions are registered; Text Editor and Rnote
  open a file given with `--file` in each sandbox, and its directory is
  granted to neither; [`tests/gtk/ime.c`](../tests/gtk/ime.c) lives through
  a focused text view's removal; MSVC's demos, if the store has them.
- Unit tests: 80 (extensions, the registry keys' round trip in a scratch
  key, the shim's `--file` arguments, sidecars, recipes).

### Code map

| File | Change |
|---|---|
| `src/associations.zig` (new) | file associations in the registry; open shims |
| `src/run.zig`, `src/main.zig` | `--file`; `list` and `rm` for associations |
| `src/shim.zig`, `src/Sidecar.zig` | shims whose arguments are files; the shortcut a shim was started from |
| `src/process.zig`, `src/win32.zig` | the app's `STARTUPINFO` names the shortcut; registry bindings |
| `src/oci.zig`, `src/recipe.zig`, `src/builder.zig` | `associations` |
| `src/exports.zig`, `src/shortcuts.zig`, `src/Store.zig`, `src/prune.zig` | shim helpers shared; the default store; `open\` |
| `recipes/gtk4-sdk/svg2ico.sh`, `gtk-ime-filter.patch` (new), `recipes/gtk4-sdk.json` | icons; GTK's input method |
| `recipes/gtk4.json`, `recipes/gnome-text-editor.json`, `recipes/rnote.json`, `recipes/rnote/save-in-place.patch` (new) | icons, associations, pins; Rnote saving in place |
| `recipes/gtk4-msvc.json` (new) | GTK with MSVC |
| `tests/sandbox.sh`, `tests/shims.sh`, `tests/gui.zig`, `tests/gui/app.json` | `--file`; associations; the shortcut an app counts as started from |
| `tests/gtk.sh`, `tests/gtk/ime.c` (new) | icons, associations, `--file` with the apps, the input method, MSVC's demos |
| `README.md` | opening a file, file associations, GTK (input method, icons), Rnote, known gaps |

## Results

### Tests

- Unit tests: 80 pass.
- `tests/sandbox.sh` 48, `tests/shims.sh` 54, `tests/store.sh`, `tests/batch.sh`
  and `tests/ctrlc.sh`: all pass.
- `tests/build.sh`: 106 pass (717 s).
- `tests/matrix.sh`: every result as intended, the three known
  AppContainer gaps aside.
- `tests/gtk.sh`: 73 pass, the six for MSVC's image among them. Before the
  GTK patch, the three checks that have Text Editor open a file failed,
  and `tests/gtk/ime.c` crashed; the rest passed.
- `tests/published.sh` for seven of the images that aren't GTK's (BusyBox,
  MinGit, Node, Prettier, Python, zig, SQLite), rebuilt with this zigsaw:
  all match ghcr.io. The other nine weren't rebuilt; nothing in their
  recipes or in what zigsaw writes for them changed.

### Reproducibility

Built in `D:\zs\a` and again in `D:\zs\b`, the same in both:

| Image | Manifest |
|---|---|
| `org.gtk.Gtk4.Sdk` 4.24.1 | `306a0507` |
| `org.gtk.Gtk4` 4.24.1 | `28c0ec8e` |
| `org.gnome.TextEditor` 51.0 | `8f60f2b0` |
| `com.github.flxzt.rnote` 0.14.2 | `c3332645` |
| `org.gtk.Gtk4.Msvc` 4.24.1 (this machine's MSVC 14.51.36231, Windows SDK 10.0.26100.0) | `a1dc4c79` |

No other image changes: configs without associations don't mention them.

### By hand

- Against the real `HKCU\Software\Classes`, from a scratch store: the
  shell's own functions list the fixture's app first for its extension, as
  recommended, under its shortcut's name and with its icon, and resolve the
  extension to its command; `zigsaw rm` leaves neither key behind.
- Rnote, opened on a document with `--file` under `--sandbox=low` and
  under `--sandbox=appcontainer`, saved it at Ctrl+S: the file was written
  again, nothing else appeared in its directory, and the directory has no
  label or grant.
- The MSVC build's Adwaita demo, in a screenshot: text, symbolic icons and
  the dark style drawn as the zig build draws them.
- Not done from here: pinning a window to the taskbar. The
  app does count as started from its shortcut (the shim suite checks it);
  what the taskbar makes of that is for the user to see.

### Measurements

| | |
|---|---|
| GTK SDK build | 26.3 min (iteration 15: 26) |
| Runtime, now a build with the SDK | 19 s |
| Text Editor build | 98 s; its layer 2.2 MB gzip, as before |
| Rnote build | 19 min; 18.0 MB gzip |
| `org.gtk.Gtk4.Sdk`'s own layer | 73.4 MB gzip (unchanged to the 0.1 MB) |
| `org.gtk.Gtk4` | 52.4 MB gzip |
| GTK with MSVC | 8.9 min; 35.1 MB gzip, 91 MB of files |
| The same modules with zig | 14.4 min; 52.7 MB gzip, 161 MB, 27 MB of it translations |
| The stack's DLLs, zig and MSVC | 30 files, 26.9 MB; 31 files, 23.1 MB |
| `gtk4-demo` to its window, zig and MSVC | 0.7 s both, warm; 130 MB of memory both |
| An `.ico` of Text Editor's SVG, six sizes | 11 kB |

## Decisions made along the way

- **Patch Rnote**, and **patch GTK** (above), both the user's.
- **No `FriendlyAppName`.** Against the real
  registry, `Application\ApplicationName` and `ApplicationIcon` alone give
  "Open with" the app's name and icon (the shim has neither);
  `shell\open\FriendlyAppName` gives the name too but not the icon.
- **The app's name and icon in "Open with" are its shortcut's**, for the
  same export, or the export's name and executable.
- **Icons in recipes, not in zigsaw**: zigsaw has no SVG renderer, and the
  SDK has. The runtime's recipe became a building one for it (50 seconds),
  which spared rebuilding the SDK, until the GTK patch did need that.
- **Text Editor's and Rnote's builds weren't the first place the input
  method's crash showed**, only the first time a test opened a file with
  Text Editor: every earlier check started it empty.

## Bugs found

- **GTK 4.24.1, Windows**: `GtkIMContextIME` leaves its display message
  filter registered when its widget loses its surface before the focus,
  and on dispose; the next message reads the freed context. Patched;
  [`tests/gtk/ime.c`](../tests/gtk/ime.c) reproduces it in 40 lines; report
  drafted.
- **Rnote 0.14.2**: saving fails where the document can be written and its
  directory can't. Patched; report drafted.
- **rsvg-convert** (our build) misreads an SVG given as a file or as
  redirected standard input ("XML parse error ... Excessive depth"), and
  reads it through a pipe. Iteration 13 saw the first half.

## Findings

- A grant of a file, where zigsaw expected a directory, already worked:
  Windows drops the inheritance flags of a low label on a file (`(NW)`),
  and an AppContainer opens a file its capability is granted by its full
  path, with nothing granted on the directories above. `gio info`, reading
  and saving work; the file beside it is denied.
- GLib's `g_file_replace` writes in place when it can't make its temporary
  file next to the target; asked for a backup (`gio save -b`), it fails.
- An `.ico` whose images are all PNGs, the 16-pixel one too, loads at every
  size with its transparency (`PrivateExtractIconsW`).
- "Open with": a key's `Application\ApplicationName` and `ApplicationIcon`
  name and picture the app. With neither, Windows shows the command's file
  name and icon, which for a shim are `rnote.exe` and none. An extension
  with only an `OpenWithProgids` entry of ours resolves to it
  (`AssocQueryString`), and `SHAssocEnumHandlers` lists it first, as
  recommended.
- Explorer puts a shortcut's path in the `STARTUPINFO` of what it starts
  from one (`lpTitle`, with `STARTF_TITLEISLINKNAME`), `Start-Process` on a
  `.lnk` included; passed on, it reaches the app two processes later.
- Text Editor and Rnote are single-instance over D-Bus here too: a second
  start with a file returns at once (exit code 0), and the running window
  opens the file. A low run's label is on the file by then, whichever
  instance opens it.
- A crash under Git Bash's `timeout` showed as exit code 127 with nothing
  printed; the Application event log had the access violation and the
  offset in `libgtk-4-1.dll`, and the DLL's export table placed it in
  `gtkimcontextime.c`.
- The build cache's key includes zigsaw's own executable, so a rebuilt
  zigsaw builds every recipe again: `tests/gtk.sh` rebuilt Rnote (21
  minutes) after a zigsaw change, to the same digest. It takes a zigsaw's
  path, and the one that built the images finds them in the cache.
- Text Editor's own layer has the same digest (`235de8a1`) built against
  the SDK before and after GTK's patch: only its pins changed.
- MSVC: `cl` and `link` read `CL` and `LINK` themselves, so `/Brepro` and
  the prefix's directories reach every compile and link, whatever the
  build system; the librarian (`lib`) reads neither, and its archives
  carry the time. With the two static libraries it made left out, every
  one of the image's 2,348 files is the same from two builds in two
  stores.
- BusyBox's sh passes imported variables on with their names in capitals
  (`$VCTOOLSREDISTDIR`), and has a `link` applet, which `which link` finds
  first; Meson, CMake and Ninja start MSVC's `link.exe` themselves.
- Meson names a static library `libintl.a` under MSVC too, and finds a
  library for `-lintl` only as `intl.lib`.
- GTK 4.24 draws its symbolic SVG icons itself: the MSVC build, with no
  librsvg, shows them. An SVG as an image through GdkPixbuf still needs
  the loader.

## Known gaps

- zigsaw offers an app for a kind of file and can't make it the default.
  Extensions only: no MIME types, URL schemes, "New" entries or other
  commands.
- `--file` grants the file and nothing beside it, and until `zigsaw rm`:
  a file opened once under `--sandbox=low` stays writable to any
  low-integrity process until then.
- What the taskbar pins for a window of an app started from a zigsaw
  shortcut hasn't been seen: the app counts as started from the shortcut,
  which is as far as a test goes without pinning by hand.
- Not looked at: what Rnote's watching of its document for changes does in
  an AppContainer that was granted the file alone; associations on a
  Windows whose display language isn't English; Explorer's "Open with"
  dialog itself, beyond what the shell's own functions report.
- GTK built with MSVC is an experiment (below), not published, not in CI.
- GTK's images, gettext and Rnote still aren't checked in CI.
- The gaps of earlier iterations otherwise remain (README's known gaps).

## Suggested for iteration 17

- The user publishes GTK's SDK, runtime, Text Editor and Rnote again.
- File the drafted reports: GTK's input method, Rnote's saving, and those
  of iterations 14 and 15 still open.
- GTK back in CI, perhaps pulling the published images and running
  `tests/gtk.sh` rather than building them.
- MSVC, if it's worth more: librsvg with Rust's MSVC target, an SDK and
  runtime split, a way to pin or at least check the Visual Studio version.
- An SDK export of `svg2ico`, so that apps outside the recipes can make
  icons; URL schemes and MIME types for associations.
