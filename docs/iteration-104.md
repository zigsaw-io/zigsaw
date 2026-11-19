# Iteration 104: GNU make in builds

Started 2026-11-19, from "plan to support GNU make". GNU make 4.4.1 has been an image
since iteration 46 (`org.gnu.make`), but only PostgreSQL's three extensions built with
it; every other recipe that ran `make` got BusyBox's, which runs one job at a time and
needed workarounds: gettext's `pmake.sh`, Gnumeric's `pdpmake.sh`, OpenSSL's
`make -n | xargs -P`, intltool's suffix rule, enchant's sed. Now **published recipes
build with GNU make: GTK's SDK brings it to every recipe that lists the SDK, gettext pins
it, and CI fails a published recipe that runs `make` without it**. PostgreSQL's SDK,
Ghostscript and GDAL's SDK are next. zigsaw is **0.104.0**. Fourteen images get new
digests; their files don't change. How recipes use it is in
[recipes](recipes.md#gnu-make).

State at the start: 103 had landed (`be28630`, Reproduce 44284326682 and Release
v0.103.0 44358988827 green).

## Outcome

- **GTK's SDK has GNU make among its runtimes.** A build gets an SDK's runtimes with
  their aliases, so a recipe that lists the SDK gets `make` and `gmake` as GNU make,
  pinned by the SDK's digest, without naming it. The SDK's own `make` export is GNU
  make now, and it exports `gmake` too.
- **gettext pins GNU make in its `"sdk"`.** Its `pmake` module is gone; libiconv and
  gettext build with `make -j"$(nproc)"`.
- **The workarounds are gone:** OpenSSL builds with `make -j build_sw`; enchant takes
  `nodist_doc_DATA=` on the command line again, without a sed; Gnumeric loses
  `pdpmake.sh` and intltool's suffix rule. `autotools-mtimes.sh` stays: GNU make needs
  release tarballs' times ordered too ([findings](findings.md#gnu-make-in-builds-iteration-104)).
- **`scripts/check-make.sh`**, in the Reproduce workflow's `pins` job: a published
  recipe whose build or vendor commands run `make` must reach `org.gnu.make`, through
  its own `"sdk"` or `"runtimes"`, or through an SDK or runtime whose recipe lists it in
  `"runtimes"`. PostgreSQL's SDK, Ghostscript and GDAL's SDK are allowed until their turn.
- **`zigsaw build` says when a build's `make` is BusyBox's**, once per build, in a note
  naming the module: one job at a time, no pattern rules or `$(shell)`, and how to get
  GNU make. It matches `make` as a command, not `cmake`, `automake` or `$(MAKE)`.
- **The builder runs commands with `busybox.exe` before any `sh.exe`.** GNU make's image
  has an `sh.exe` that starts BusyBox's sh, for make's recipe lines; found first, it
  added a process under every command of every build that had make. No digest moves:
  pgvector and pg_cron, built through it until now, rebuild to their published images.

## Decisions

| Decision | Choice |
|---|---|
| What "default" means | Pinned and enforced (your pick): zigsaw adds no tool to a build by itself, as that would be an input the recipe doesn't pin. Recipes reach GNU make through the SDK they use, or their own pin, and CI checks they do |
| Where GNU make lives | Among GTK's SDK's runtimes. In BusyBox's image it would be everyone's, but about 70 images would be republished, and GNU make's recipe pins BusyBox, so it can't be inside it |
| Which recipes first | The GTK family (your pick): gettext, GTK's SDK, Gnumeric, and the 11 images that pin them. PostgreSQL's SDK (OpenSSL), Ghostscript (with TeX Live) and GDAL's SDK (libiconv), and the extensions' older make pin (`045e39d4` to `9add04a4`), are iteration 105 |
| A build without GNU make | Builds, with a note. A user's recipe keeps working |
| `autotools-mtimes.sh` | Kept, unchanged. Its comment blames BusyBox's make alone, which is no longer the whole story, but its bytes are an input of the images that copy it, GDAL's SDK among them |

## Files

- `src/builder.zig`: the note (`runsMake`, `namesMake`, with a unit test), `findShell`'s
  order. `src/aliases.zig`: `find` is public.
- `tests/build.sh`, the make section (`cmake-meson` group): no note with GNU make; an SDK
  with GNU make as a runtime gives it to a recipe that lists only the SDK; BusyBox's make
  builds, noted. `tests/build/make-sdk/` (new).
- `tests/gtk.sh`: the icon extension's fixture takes BusyBox's digest from GTK's SDK
  recipe, not from the store's installed BusyBox, which a store that only built the SDK
  hasn't got (its three rows failed in store `p` for that).
- `scripts/check-make.sh` (new); its step in `.github/workflows/reproduce.yml`.
  `scripts/published-recipes.txt`: make before gettext. `scripts/ci-groups.sh`: make's
  recipe in the GTK groups' paths.
- `recipes/gettext.json`, `recipes/gtk4-sdk.json`, `recipes/gnumeric.json`;
  `recipes/gnumeric/pdpmake.sh` deleted; 11 recipes re-pinned.
- `docs/recipes.md`, `docs/gaps.md`, `docs/findings.md`, `docs/published-apps.md`;
  0.104.0 in `build.zig.zon` and `zigsaw.json`.

## Results

| what | result |
|---|---|
| unit tests | pass, on the final source; new in `src/builder.zig` (`make` as a command, not in another word) |
| `tests/build.sh`, sections `commands contained cmake llvm meson make` | 71 ok, 0 failed (608 s); the make section's new rows among them |
| pgvector, pg_cron | rebuilt with `busybox.exe` ahead of make's `sh.exe`: their published digests |
| the round | 14 images in store `p`, then from the pinned recipes in `E:\zs\i104\p2`: the same 14 digests. Every image's own layers are the ones on ghcr.io |
| `scripts/check-make.sh` | 9 recipes run make, 0 without GNU make (3 allowed until iteration 105); before the recipes changed, it failed gettext, GTK's SDK and Gnumeric |
| `scripts/check-pins.sh` | 28 missing, all the round's new digests; 0 older runtimes |
| `tests/gtk.sh`, store `p` | 94 ok, 0 failed (after the fixture's fix; MSVC skipped, not in the store) |
| `tests/gtk3.sh`, store `p` | 45 ok, 0 failed |
| Gnumeric's translations | 62 languages for `gnumeric-1.12.62.mo` and its functions' catalog, 58 for goffice's, 51 for libgsf's: the layer is the published one |
| the package | zip `578adc83`, 0.104.0; Defender finds nothing in its six programs |

## Images

Built in store `D:\zs\i104\p` with the frozen 0.104.0 (`D:\zs\i104\bin`), each also in
`E:\zs\i104\p2` from the pinned recipes:

| Image | Digest | Time here | New layers |
|---|---|---|---|
| `org.gnu.gettext` | `9eb87582fe33` | 25.7 min | none |
| `org.gtk.Gtk4.Sdk.Base` | `78fd3abd6137` | 15 min | none |
| `org.gtk.Gtk4.Sdk` | `34efa61b7ef0` | 14.9 min | GNU make's (`c399a41e`, 222 KB), as a runtime |
| `org.gtk.Gtk4` | `4ac2ac501d9a` | 21 s | none |
| `org.gnome.TextEditor` | `d686bcd4feb3` | 85 s | none |
| `com.github.flxzt.rnote` | `d5bfb7885ca9` | 13.3 min | none |
| `org.gtk.Gtk3.Sdk` | `da90d8580473` | 2.7 min | none |
| `org.gtk.Gtk3` | `b47da49ceab7` | 4 s | none |
| `org.gtk.Gtk3demo` | `337eb79d7c51` | 7 s | none |
| `org.gnome.Gnumeric` | `c6b6837495ed` | 13.4 min (21 before) | none |
| `org.gnome.PyGObject.Sdk` | `9c70f4269939` | 31 s | none |
| `org.gnome.PyGObject` | `fd4da23710a3` | 4 s | none |
| `org.gnome.Meld` | `7010727aca3a` | 67 s | none |
| `org.gaphor.Gaphor` | `89a8d20f8ad6` | 2.5 min | none |

Pinta (no-publish) stays on the old pins.

## Not checked

- **CI's side**: `check-make.sh` ran here, with jq on Git Bash; the `pins` job runs it
  on Linux.

## Not this time

- PostgreSQL's SDK, Ghostscript and TeX Live, GDAL's SDK and what pins them; the
  extensions' make pin; `check-make.sh`'s allow list. Iteration 105.
- Qt's SDK still exports BusyBox's make as `make`; no published recipe runs it.
- zig 0.17.1 and CMake 4.5.0, from the upstream report.

## Yours to do

1. **Publish the 14 images before pushing**, in this order, with the frozen exe:

   ```
   ZIGSAW_HOME='D:\zs\i104\p' ZIGSAW='D:\zs\i104\bin\zigsaw.exe' scripts/publish.sh gettext.json gtk4-sdk-base.json gtk4-sdk.json gtk4.json gnome-text-editor.json rnote.json gtk3-sdk.json gtk3.json gtk3demo.json gnumeric.json pygobject-sdk.json pygobject.json meld.json gaphor.json
   ```

   Only GNU make's layer and the configs and manifests are new to ghcr.io.
2. Commit and push (`scripts/check-make.sh`, `tests/build/make-sdk/` and this file are
   new; `recipes/gnumeric/pdpmake.sh` is deleted). I read the Reproduce run: `pins`
   (check-make) first, then the GTK groups.
3. The tag `v0.104.0` is yours; I read the Release run after it.
