# Iteration 72: GTK and Python, and a crash on a reset connection

Built 2026-11-05. Most of the advisories the report listed sat in GTK's SDK base, so this round
moved it: libtiff, libpng, CPython, HarfBuzz, FreeType, PCRE2, librsvg, Hunspell and setuptools,
plus six in-series updates that cost no extra rebuild. 20 images to publish. It wasn't meant to
touch zigsaw's code, but a build crashed on a real connection reset, in a bug every release has,
so zigsaw is now **0.72.0**, and that reaches nobody until it's tagged. Findings are in
[findings.md](findings.md#a-connection-reset-while-downloading) and
[findings.md](findings.md#advisories).

## Outcome

- **20 images built, the same 20 digests in two stores** with separate downloads and vendor steps.
- **The report went from 15 pinned versions with advisories to 11.** libtiff, libpng, FreeType,
  setuptools and `python-nuget` cleared. CPython's published image and PostgreSQL's PL/Python are on
  3.14.10. One row is new: see the libjpeg-turbo point below.
- **A reset connection no longer crashes zigsaw.** During a layer it resumes, and during a manifest
  it's an ordinary error. In every earlier release both were a panic, so iteration 66's resuming had
  never survived a real reset.
- **All six extra updates stayed.** None broke a build or a patch, so none went back.

## Starting decisions

Yours: the GTK + Python round over everything in the report, updates reaching people or signed
images; and adding GLib 2.90.1, glib-networking 2.90.1, libsoup 3.8.1, nghttp2 1.71.0, gdk-pixbuf
2.43.5 and libjpeg-turbo 3.1.4.1.

Mine, in the plan: zlib waits for its release; Meson and Qt's SDK stay on CPython 3.14.7, which they
only build with; `gtk4-msvc` moves too, so it doesn't keep old rows in the report.

Decided during (mine, not in the plan):

- **Fixing the panic in this round, and so changing the plan's "no code, stays 0.70.0".** It killed
  a build here, and it would do the same to anyone pulling over a bad connection. The version
  is 0.72.0. The tag is yours.
- **The images stay built with the frozen 0.70.0**, as the build cache keys on zigsaw's exe. `python`,
  `gtk4` and `postgresql-pg-cron` rebuilt with 0.72.0 give the same digests, so CI's comparison
  with 0.72.0 should hold.
- **libjpeg-turbo stays on 3.1.4.1, though it adds a row.** `OSV-2026-1068` is a crash in the
  TurboJPEG API, which the recipes don't build, and the commits it names don't touch code.

## What was built

- `src/Registry.zig`: `bodyFailure` asks the connection why a body broke off.
- `tests/resetproxy.zig`, `zig build resetproxy`: a proxy that sends a real RST. Two rows in
  `tests/registry.sh`.
- `recipes/gtk4-sdk-base.json`, `recipes/gtk4-sdk.json`, `recipes/python.json`,
  `recipes/pygobject-sdk.json`, `recipes/postgresql-sdk.json`, `recipes/gtk4-msvc.json`: the sources.
  The other recipes in the chain were re-pinned by `rebuild.sh`.
- `tests/gtk.sh` expects libsoup 3.8.1, and `tests/postgresql.sh` Python 3.14.10.

| Source | From | To |
|---|---|---|
| libtiff | 4.7.0 | 4.7.2 |
| libpng | 1.6.49 | 1.6.59 |
| CPython, and its NuGet package | 3.14.7 | 3.14.10 |
| HarfBuzz | 14.4.0 | 14.6.0 |
| FreeType | 2.14.3 | 2.15.0 |
| PCRE2 | 10.46 | 10.49 |
| librsvg | 2.63.2 | 2.63.4 |
| Hunspell | 1.7.5 | 1.7.6 |
| setuptools | 84.0.0 | 84.2.1 |
| GLib | 2.90.0 | 2.90.1 |
| glib-networking | 2.90.0 | 2.90.1 |
| libsoup | 3.8.0 | 3.8.1 |
| nghttp2 | 1.70.0 | 1.71.0 |
| gdk-pixbuf | 2.43.3 | 2.43.5 |
| libjpeg-turbo | 3.1.1 | 3.1.4.1 |

## Results

| Image | Digest | Time here |
|---|---|---|
| `org.python.python` | `ccd0d0e3ef77` | 2 s |
| `org.gtk.Gtk4.Sdk.Base` | `b4fe60e66ea5` | 14 min |
| `org.gtk.Gtk4.Sdk` | `6a709d2c64ec` | 13 min |
| `org.gtk.Gtk4` | `121bdd39952a` | 17 s |
| `org.gnome.TextEditor` | `faf70beaa090` | 79 s |
| `com.github.flxzt.rnote` | `34e4f805ff52` | 13 min |
| `org.gtk.Gtk3.Sdk` | `a6695ebad1d2` | 2.4 min |
| `org.gtk.Gtk3` | `53af52434d6d` | 3 s |
| `org.gtk.Gtk3demo` | `e4ea133acfb5` | 5 s |
| `org.gnome.Gnumeric` | `551c9f5ce23f` | 21 min |
| `org.gnome.PyGObject.Sdk` | `6c6210a064d9` | 29 s |
| `org.gnome.PyGObject` | `b2a5ae924bf3` | 3 s |
| `org.gnome.Meld` | `9d47bae46938` | 46 s |
| `org.gaphor.Gaphor` | `f999fc3c866c` | 2 min |
| `org.postgresql.PostgreSQL.Sdk` | `c4055aed101d` | 7.6 min |
| `org.postgresql.PostgreSQL` | `dff67fdaeadf` | 6 s |
| `org.postgresql.PostgreSQL.pgvector` | `b8e7ece039b1` | 12 s |
| `org.postgresql.PostgreSQL.pg_cron` | `b6692cec594c` | 6 s |
| `org.postgresql.PostgreSQL.PostGIS` | `7a1bd1d4558c` | 2.4 min |
| `org.osm2pgsql.osm2pgsql` | `240eaaef25f5` | 2 min |

`org.gtk.Gtk4.Msvc`, which isn't published, built once here in 9 min 14 s (`72aa57bf08ba`).

| Check | Result |
|---|---|
| `tests/gtk.sh`, with store `p` | 100 ok, 0 failed, the MSVC rows and Rnote's windows among them |
| `tests/gtk3.sh` | 45 ok, 0 failed |
| `tests/postgresql.sh` | 49 ok, 0 failed |
| `tests/osm2pgsql.sh` | 43 ok, 0 failed |
| `tests/upstream.sh`, `tests/rebuild.sh` | 68 ok and 31 ok, 0 failed |
| `tests/registry.sh`, with 0.72.0 | 111 ok, 0 failed, the two reset rows among them |
| `tests/self.sh`, on the package | 17 ok, 0 failed |
| `zig build test` | passes |
| `rnote.exe`, `rnote-cli.exe`, `rsvg-convert.exe` | bind all their imports |
| Defender on store `p`'s deployments | no threats, 68,749 files |
| `scripts/defender-scan.sh` on 0.72.0's package | all five programs clean |
| `scripts/check-pins.sh` | 35 missing, all this round's digests, and the 4 intended older runtimes |

`tests/gtk.sh` needed three runs to get there, and the images weren't the cause. The first failed on
the libsoup version the test hard-coded, and because my store had BusyBox only as a build dependency.
The second failed because I'd pulled BusyBox by digest, which writes that digest into its ref twice,
and the suite's `manifest_of` expects one. Pulled by tag, as CI does, it passed. `tests/upstream.sh`
also failed 7 rows once, under `MSYS_NO_PATHCONV=1` and a backslashed `TMPDIR` that I'd exported, and
passed in a plain environment.

The report says what the plan expected, with the one addition:

| | Rows |
|---|---|
| Cleared | libtiff, libpng, FreeType, setuptools, `python-nuget` |
| Still listed at the new version | HarfBuzz 2, PCRE2 1, librsvg 1, Hunspell 1 |
| **New** | libjpeg-turbo 3.1.4.1: `OSV-2026-1068` |
| Unchanged | zlib 2; `python` 3.14.7, for Meson and Qt's SDK; expat; boost; libxml2; fzf |

Each source's hash was compared with upstream's where upstream publishes one: GitHub's digests for
PCRE2, HarfBuzz, libjpeg-turbo, Hunspell and nghttp2; GNOME's sha256sum for GLib, gdk-pixbuf,
librsvg, glib-networking and libsoup; PyPI for setuptools; NuGet's catalog for the Python package.

## What the updates fix, from upstream's notes

- **glib-networking 2.90.1**: 5 CVEs, among them CVE-2026-113622, an extended key usage bypass in
  the OpenSSL backend, the one the SDK builds. OSV's report showed nothing for this row.
- **gdk-pixbuf 2.43.5**: a JPEG crash, CVE-2025-7345.
- **libpng 1.6.59**: CVE-2026-46675. **FreeType 2.15.0**: CVE-2026-95512. **PCRE2 10.49**:
  security fixes only.
- **libsoup 3.8.1**: limits on redirect and auth bodies. **GLib 2.90.1**: hardening throughout.
- **librsvg 2.63.4** now follows EXIF orientation in embedded images, so SVGs that assumed it
  didn't render differently. That's a behaviour change an app could notice.

## Not checked

- **CI**, which rebuilds on a fresh runner and so tests reproduction across machines. That's after
  the push. Gnumeric and the two SDKs are the ones to watch.
- **v0.72.0's Release**: its scan and hashes come with your tag. The package here is
  `c03b44dd357d`, scanned clean, and Defender judges exact bytes, so CI's scan still counts.
- **Whether `OSV-2026-1068` applies.** I read the record and the commits, and didn't try the crash.
- **Hashes I couldn't compare**: libtiff publishes only a signature, and libpng's archive is
  GitHub's. FreeType's is the same on a second host. CPython's matches its sigstore bundle's digest,
  but I didn't verify the signature.
- **Notes on the newer runner image**, still open from iteration 71. The green `qt-suites` ran on the
  older image, 20261030.294, and the red one on 20261103.298. This round doesn't touch Qt. The weekly
  run on 2026-11-09 should re-check it.
- `tests/matrix.sh`, and suites unrelated to this round: CI runs them.

## On this machine

Scratch is in `E:\zs\i72` and `D:\zs\i72`. `E:\zs\i72\p` is what you publish from, so keep it until
then. `zigsaw grants`, with `ZIGSAW_HOME` on a store here, lists low labels on folders under
`D:\zs\i72\tmp`, from the suites: scratch, nothing of yours. The repository and your Documents,
Desktop, Downloads, Pictures, Music and Videos have no low labels or capability ACEs.

`C:\Users\Test` does have one capability ACE, `S-1-15-3-65536-599108337-...`, allowing traverse only.
I don't think it's zigsaw's: zigsaw's capabilities start `S-1-15-3-1024-`, nothing in its code writes
one starting `65536`, and `C:\`, `C:\Users` and `C:\Users\Default` have ACEs of that form too, with
other SIDs. I don't know what wrote any of them, or how long this one has been there; no earlier
check looked at the profile folder itself. It looks like Windows' own. I left it alone.

## Next

- **Publish before pushing**, from the store that built them, in this order:
  `ZIGSAW_HOME='E:\zs\i72\p' ZIGSAW='E:\zs\i72\bin\zigsaw.exe' scripts/publish.sh python.json gtk4-sdk-base.json gtk4-sdk.json gtk4.json gnome-text-editor.json rnote.json gtk3-sdk.json gtk3.json gtk3demo.json gnumeric.json pygobject-sdk.json pygobject.json meld.json gaphor.json postgresql-sdk.json postgresql.json postgresql-pgvector.json postgresql-pg-cron.json postgresql-postgis.json osm2pgsql.json`
- **Then commit and push**, with `tests/resetproxy.zig`, which is new. I'll read Reproduce.
- **Tag v0.72.0**, your call: the fix reaches nobody without it. I'll read Release and compare its
  hashes with a build here.
- **`zstest` can go**, and `E:\zs\i71` too, after `zigsaw rm` of what's in that store.
- Next round: **zlib**, when it has a release (the fix for CVE-2026-85091 is `df84af25`, 87 commits past
  v1.3.2). Meson and Qt's SDK onto a newer Python, which clears the `python` 3.14.7 row. expat 2.10.0,
  4 images.
- Later: a report column separating what ships from what only builds; updates that reach people who
  don't ask; signed images.
