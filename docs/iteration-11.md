# Iteration 11: GUI apps on the desktop

Concluded 2026-10-06.

## Outcome

Iteration 10 built GTK and ran its demos, but GTK apps still behaved like
command-line tools: their commands were console shims, so starting one from
Explorer opened a console window, and nothing put them in the Start menu.
Zigsaw now:

- **gives GUI programs a GUI shim**, `zigsaw-shimw.exe`, chosen by the
  subsystem in the executable's PE header. Started from Explorer or the
  Start menu, it opens no console, and neither does the zigsaw it starts.
  When it has nowhere to write errors, it shows the end of what zigsaw and
  the app wrote in a message box if the app fails;
- **adds Start menu shortcuts** that recipes declare (`shortcuts`), as
  Flatpak apps export `.desktop` files, and keeps them in step with
  installs, updates and `rm`;
- **has libadwaita 1.10** in GTK's SDK and runtime, with the Adwaita and
  hicolor icon themes, as GNOME's runtime does;
- **publishes GNOME Text Editor 51.0**, built from source on GTK's runtime,
  the first GUI app of note;
- **leaves GTK out of CI** for now: the Reproduce workflow skips GTK's
  images and Text Editor, and `tests/gtk.sh` runs locally.

Getting Text Editor built took four small patches in recipes (libxml2's
`git describe`, libadwaita's demo files and subsystem, Text Editor's help),
and the GUI shim's first real run found that GTK's widget factory has
aborted at startup since iteration 10.

## Starting decisions

From the planning session (plan file
`plan-iteration-11-iridescent-starfish.md`):

- Scope, the user's choice: GUI apps on the desktop (a GUI shim chosen by
  PE subsystem, Start menu shortcuts), a GTK app of note, and GTK out of CI
  until it's stable locally. Not this time: fixing zig's `rc` alias.
- Shortcuts are **declared in the recipe**, over shortcuts for every GUI
  export or ones users add.
- The app: **GNOME Text Editor 51.0** (MSYS2 ships it on Windows), over the
  libadwaita demo alone or a gtk4-rs app.
- libadwaita goes **into GTK's SDK and runtime**, like GNOME's runtime, over
  bundling it in the app; Text Editor's other libraries (libxml2,
  GtkSourceView, libspelling) are its own modules.
- CI: keep Meson's image (`tests/build.sh` builds with it), skip GTK's
  images and Text Editor, drop `tests/gtk.sh`.
- Planning found, with `gh` now working here, that iteration 10's Reproduce
  run reproduced all 18 images and failed only `tests/gtk.sh`'s OpenGL
  check (the runner has no GPU); the other 7 GTK checks passed on the
  runner.

Defaults chosen in the plan: a separate `zigsaw-shimw.exe` rather than
patching one shim's header; the GUI shim starts zigsaw with
`DETACHED_PROCESS` rather than a hidden console, which at logoff would get
`CTRL_SHUTDOWN_EVENT` and end the app before it could save; shortcuts only
for the default store unless `ZIGSAW_SHORTCUTS_DIR` says otherwise, so test
stores never touch the real Start menu; a shortcut's owner read from its
target, with no new state; GTK's images keep version 4.24.1, their tags
overwritten when republished, as zig's were.

## What was built

**The GUI shim** ([`src/shim.zig`](../src/shim.zig)). The same program as
`zigsaw-shim.exe`, built a second time with a `gui` build option and
Windows' GUI subsystem, as `zigsaw-shimw.exe`. It starts zigsaw with
`DETACHED_PROCESS`, so zigsaw gets no console and doesn't open one. GTK apps
don't need one. What happens to errors depends on whether whoever started
the shim gave it a file or pipe for stderr (`GetFileType`, checked before
the shim opens any file, since a GUI program started from a console can find
another process's handle values in its std slots):

- with one (Git Bash, `2>log.txt`), zigsaw and the app write there, and the
  exit code passes through;
- without (Explorer, the Start menu, `Start-Process`), zigsaw's stdout and
  stderr, which the app inherits, go to a pipe whose last 8 KB the shim
  keeps; if the app exits with an error, the shim shows the last 20 lines
  and the exit code in a message box. Its own errors (a missing sidecar) go
  the same way. `ZIGSAW_SHIM_REPORT=<file>` writes the message to a file
  instead, for tests.

`process.spawn` became `start` and `Child.wait`, with the child's
creation flags and stdio handles as options, so the shim can read the pipe
while zigsaw runs.

**Choosing the shim** ([`src/pe.zig`](../src/pe.zig),
[`src/exports.zig`](../src/exports.zig)). When an app is installed, and
after its runs, each command's file (an export's, in the app's or a
runtime's deployment, or one a run installed) is checked: a PE file whose
subsystem is `IMAGE_SUBSYSTEM_WINDOWS_GUI` gets the GUI shim, anything else
the console one. The sidecar records it (`gui = true`); older sidecars read
as console. A command that changes kind gets the other shim on its next
sync, since shims are rewritten when their bytes differ.

**Start menu shortcuts** ([`src/shortcuts.zig`](../src/shortcuts.zig)). A
recipe's `shortcuts` names each shortcut and the export it runs, with an
optional `description` and `icon`; the config has the field only when the
recipe does, so other images keep their digests. Installing writes
`<name>.lnk` with the shell's `IShellLinkW`, through hand-written COM
bindings: the target is the export's shim in `<store>\bin`, the working
directory the app's home in its data directory (a shortcut's own would be
System32, which `cwd` grants under `low` and `appcontainer` mustn't label or
grant), and the icon the `icon` file or the export's executable, in the
deployment, so updates rewrite it. Updates remove shortcuts the app no
longer declares, `rm` removes the app's, and an emptied folder goes too.

The folder is `<Start menu>\Programs\Zigsaw` for the default store only, or
`ZIGSAW_SHORTCUTS_DIR` for any store. A shortcut belongs to the store if it
runs a shim in its `bin`, and to the app that shim's sidecar names; zigsaw
leaves other `.lnk` files alone, and says so when one has a name it wants.

**libadwaita in GTK's images** ([`recipes/gtk4-sdk.json`](../recipes/gtk4-sdk.json)).
Three modules after GTK: hicolor-icon-theme 0.18, adwaita-icon-theme 51.0,
and libadwaita 1.10.0, whose tarball includes its `ministream` subproject
and its compiled stylesheet, so neither network nor sassc is needed. Its
demo's metainfo and desktop files go through `i18n.merge_file`, which needs
gettext's `msgfmt`; the recipe turns those into `configure_file(copy:
true)`, as the demo reads the metainfo at run time. Upstream builds the demo
as a console program on Windows; the recipe sets Meson's `win_subsystem`.
The runtime ([`recipes/gtk4.json`](../recipes/gtk4.json)) runs `gtk4-demo`
now, exports `adwaita-1-demo`, and declares "GTK Demo" and "Adwaita Demo".

**GNOME Text Editor** ([`recipes/gnome-text-editor.json`](../recipes/gnome-text-editor.json)).
On GTK's runtime, with its own modules: libxml2 2.15.4 (its `meson.build`
runs `git describe`, which Meson fails on when git is missing even with
`check: false`; the recipe removes it), GtkSourceView 5.22.0, libspelling
0.4.10 without enchant, editorconfig-core-c 0.12.11 (CMake, on the SDK's
PCRE2) and Text Editor 51.0, without its help pages (`gnome.yelp`; Windows
has no help viewer). Upstream already skips its desktop and metainfo files
on Windows, and builds a GUI program. Its GSettings schema is compiled into
the app's `share`, where GLib finds it next to the executable.

**CI** ([`.github/workflows/reproduce.yml`](../.github/workflows/reproduce.yml)).
`tests/published.sh` skips the recipes `SKIP_RECIPES` lists; the workflow
lists GTK's SDK, its runtime and Text Editor, drops `tests/gtk.sh`, and its
timeout is back to 60 minutes. Meson's image stays, as `tests/build.sh`
builds with it.

### Code map

| File | Change |
|---|---|
| `src/shim.zig` | the GUI build: detached zigsaw, stderr tail, message box, `ZIGSAW_SHIM_REPORT` |
| `src/process.zig` | `start` and `Child.wait`; `creation_flags`, `stdio` |
| `src/pe.zig` | new: a PE file's subsystem |
| `src/exports.zig` | shim kind per command; `findCommands` returns paths; shortcuts synced with shims |
| `src/Sidecar.zig` | `gui` |
| `src/shortcuts.zig` | new: Start menu shortcuts |
| `src/oci.zig` | `Shortcut`, `AppConfig.shortcuts` and its checks; `Placeholders.commandPath` (from `run.zig`); `zigsaw-shimw` reserved |
| `src/recipe.zig`, `src/builder.zig` | `shortcuts` in recipes; icons checked like commands |
| `src/main.zig` | `rm` removes shortcuts, `list` shows them |
| `src/win32.zig` | pipes, file types, `MessageBoxW`, COM and shell bindings |
| `build.zig` | `zigsaw-shimw`; `gui-fixture`; ole32 and shell32 |
| `recipes/gtk4-sdk.json`, `recipes/gtk4.json` | icon themes, libadwaita; runtime command, exports, shortcuts |
| `recipes/gnome-text-editor.json` | new |
| `tests/gui.zig`, `tests/gui/app.json` | new: a GUI program and its test app |
| `tests/shims.sh` | GUI shim and shortcut checks |
| `tests/gtk.sh`, `tests/gtk/` | libadwaita, shims, shortcuts, Adwaita demo, Text Editor |
| `tests/published.sh`, `.github/workflows/reproduce.yml`, `scripts/published-recipes.txt` | `SKIP_RECIPES`; GTK out of CI; Text Editor published |

## Results

### Tests

- `zig build test`: passes, with new tests for PE subsystems, sidecars with
  and without `gui`, the stderr tail, lossy UTF-16 for message boxes,
  shortcut names, the shortcut folder's choice, a shortcut's shim, and
  recipes with and without `shortcuts`.
- `tests/shims.sh` (41 checks, 17 new): GUI and console commands get their
  shims; with a pipe for stderr, output and exit code pass through; started
  as Explorer starts programs, zigsaw has no console (the GUI test program
  can't attach to its parent's), a failure is reported with the app's
  output, a success isn't, and zigsaw's and the shim's own errors are; a
  command that changes kind gets the other shim; a shortcut's target,
  working directory, description and icon; `list`; starting a shortcut runs
  the app; renaming; a missing icon fails the build; a foreign `.lnk` is
  kept; `rm` removes the app's shortcuts only, and an emptied folder; a
  store other than the default adds none.
- `tests/gtk.sh` (17 checks, 9 new; local only now): the test app with
  libadwaita 1.10.0; the demos' shims and shortcuts; the Adwaita demo runs;
  Text Editor 51.0 is installed with its shim and shortcut, and runs under
  soft, low and AppContainer.
- `tests/batch.sh`, `tests/ctrlc.sh`, `tests/sandbox.sh`, `tests/store.sh`:
  pass unchanged, and so does `tests/build.sh` (83 checks; builds use the
  console shim for aliases).
- Reproducibility: GTK's SDK (`ef47240f…`), runtime (`2a869bf2…`) and Text
  Editor (`3c473935…`) have the same digests built in a second, fresh store,
  whose Meson, CMake, zig and BusyBox images came from ghcr.io.
- By hand: GTK's widget factory, demo, node editor and print editor, the
  Adwaita demo and Text Editor started through their shims without a
  console (no `conhost` for zigsaw or the shim); Text Editor's window
  showed its Adwaita styling and symbolic icons.

### Measurements

| | |
|---|---|
| GTK SDK, zig's cache warm / fresh store | 15.5 / 18.2 min (iteration 10: 13–16) |
| GTK runtime from the SDK image | 17 s |
| Text Editor and its five modules | 2 min |
| `org.gtk.Gtk4.Sdk` | 107 MB, 2,423 files, 37.4 MB gzip (was 97 MB, 34.5 MB) |
| `org.gtk.Gtk4` | 73 MB, 1,038 files, 33.2 MB gzip (was 64 MB, 30.4 MB) |
| `org.gnome.TextEditor`'s own layer | 6 MB, 31 files, 1.7 MB gzip |
| `zigsaw-shim.exe` / `zigsaw-shimw.exe` | 132 KB / 138 KB |

## Decisions made along the way

- **The icon themes went into the SDK without waiting for Text Editor's
  probe**, which would have cost a second 15-minute SDK build if it had
  found icons missing; GNOME apps expect Adwaita's, and MSYS2's GTK depends
  on it.
- **`merge_file` becomes `configure_file(copy: true)`** in libadwaita's
  demo, rather than being deleted: the demo reads its metainfo at run time.
  No gettext tools; the files are untranslated.
- **editorconfig-core-c is built** for Text Editor rather than turned off
  (`-Deditorconfig=disabled`): it's small, and CMake's image and the SDK's
  PCRE2 were there.
- **The runtime runs `gtk4-demo`** instead of `gtk4-widget-factory`, which
  aborts (below), and no longer exports the widget factory.
- **`tests/gtk.sh` checks that Text Editor keeps running for 15 s**: its
  hidden `--exit-after-startup` only activates the app at startup, and
  doesn't quit.

## Bugs found

- **GTK's widget factory has aborted at startup since iteration 10**: its
  UI file gives an image an SVG resource, which GtkBuilder loads through
  gdk-pixbuf, and gdk-pixbuf has no SVG loader without librsvg (GTK's own
  SVG renderer only serves icon themes). Iteration 10's tests ran the
  factory only with `--version`. The GUI shim's first run showed GLib's
  "Unspecified fatal error" dialog, and its report the real message.

## Findings

- GTK's demos are GUI programs, and so is Text Editor; libadwaita's demo
  isn't, upstream, on Windows (no `win_subsystem`).
- Meson's `run_command('git', ..., check: false)` fails the configure step
  when git doesn't exist, rather than returning an error code (libxml2).
- Pango warns that HarfBuzz lacks DirectWrite when GtkSourceView adds its
  own font: the SDK's HarfBuzz is built without `-Ddirectwrite`.
- None of GTK's executables, nor Text Editor's, carry an icon resource;
  their icons are SVGs.
- `gh` now works on this machine, so CI logs (`gh run download`) can be
  read from here; annotations alone only said "exit code 1".

## Known gaps

- Shortcuts show a generic icon for GTK's demos and Text Editor; `icon`
  takes an `.ico`, which none of their recipes has yet.
- Pinning a running GTK app to the taskbar pins its executable in the store
  (no AppUserModelID).
- Text Editor has no spell checking (no enchant), translations or help.
- GTK's widget factory needs librsvg's pixbuf loader.
- A GUI shim can't be replaced while it runs, so updating an app whose GUI
  command is open fails, as with console shims.
- GTK's images, Text Editor and `tests/gtk.sh` aren't checked in CI.

## Suggested for iteration 12

- Republish GTK's SDK and runtime, publish Text Editor (the user's
  `scripts/publish.sh`), and watch the first Reproduce run without GTK.
- Icons for shortcuts: render an app's SVG icon to an `.ico` at build time
  (GTK's SVG renderer could), or accept PNGs and wrap them.
- librsvg (Rust, with the Rust SDK) for SVGs in gdk-pixbuf, which brings
  back the widget factory.
- HarfBuzz with DirectWrite; enchant and dictionaries for spell checking.
- GTK back in CI once stable locally, perhaps with a cached SDK.
- File associations ("Open with"), Flatpak's MIME exports.
