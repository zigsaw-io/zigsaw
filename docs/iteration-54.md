# Iteration 54: low integrity by default

Built 2026-10-28. zigsaw 0.54.0. To publish: Kanboard (a new config, the
same layer) and Xdebug (a new `.ini`), before the push.

## Outcome

- **Apps run at low integrity unless something says otherwise.** `low` has
  been opt-in since [iteration 9](iteration-9.md), whose rule was "soft
  stays the default until the matrix is green under low on both Windows
  builds"; the matrix's low column has had no gap on Windows 11 or Server
  2025 since iteration 13. What iterations 13 and 14 asked for first is in
  too: a working directory low won't label is read-only for the run, not
  refused.
- **An image may name the sandbox it runs in** (`permissions.sandbox`).
  Kanboard's and Files' ask for `soft`. `pull`, `update` and `info` show it
  as access.
- **Overrides for every app at once**: `zigsaw override --global`, below
  each app's own.
- **Every suite runs under the new default**, and every published app the
  matrix's store has runs at low as published.sh's smoke does. One image
  needed a change: Xdebug traced and profiled into `C:\Windows\Temp`,
  which a low-integrity run can't write; it now uses the run's `TEMP`.
- **Iteration 53's run, fixed.** Its push run (40616239849) reproduced every
  published group, and the 8 images were on ghcr.io. It was red in two
  suites:
  - **certs.sh**: in an AppContainer on Server 2025, psql didn't trust the
    test CA, and PHP's curl couldn't load the file of roots. The file was
    unreadable there: zigsaw wrote it in the store's `tmp\` and renamed it
    into `certs\`, so it kept the ACL it had in `tmp\`. The AppContainer
    grant on `certs\` had reached the files there when it was made, not a
    file renamed in after. On CI the test CA changes Windows' roots between
    runs, so a new file came. Runs now grant the file itself.
  - **gtk.sh**: badssl.com's untrusted-root host dropped the connection
    twice. libsoup's row now refuses a certificate made for the run, on a
    local server.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-54-gleaming-corbato.md`):

- **Low becomes the default sandbox** (your pick, over a new app, TeX Live
  collections, or faster builds).
- **A writable working directory that low won't label** (your profile, a
  folder that holds it, a drive's root) is **read-only for the run, with a
  warning** (your pick, over soft for that run, or refusing as before).
- **Labels made under the default stay as today's low overrides' do**
  (your pick): fast, but they pile up, which is a gap.
- **Images may name their sandbox, and Kanboard's asks for soft** (your
  pick, over patching Kanboard's writability checks), as Files' does.
- **A store-wide override**, `zigsaw override --global` (your pick).
- Mine:
  - The layers, Flatpak's order: the image's permissions, under the
    store-wide overrides, under the app's, under the command line; low
    when none names a sandbox.
  - One function decides the sandbox for runs and for how long grants
    last, which each had decided for itself (`orelse .soft`).
  - The read-only fallback is for the working directory only, and for
    every low run, chosen or the default: a path granted with
    `--filesystem` there is still refused.
  - Builds are unchanged: they never ran sandboxed.
  - `zig fetch` at low stays a gap: zig's compiler has its std built in.

## What was built

### Slice 0: CI's red rows

**The file of roots** ([`src/run.zig`](../src/run.zig)):

- **Reproduced here** without touching Windows' stores, in iteration 53's
  store with its zigsaw: a run of Perl in an AppContainer read `${roots}`,
  the file was deleted, a soft run wrote it again, and the next
  AppContainer run got `Permission denied`. The new file had only the
  user's, Administrators' and SYSTEM's entries, inherited in `tmp\`.
- **The fix:** an AppContainer run grants the file itself, not `certs\`.
  Granting it also brings back what `certs\` passes down, and once it's
  there it's a no-op. An AppContainer reads the file with nothing on
  `certs\` for it: its token may traverse directories.
- **Not the relay.** Its copy is written the same way, and has the same
  ACL after an upgrade, but it starts in a container regardless:
  `CreateProcess` opens the program with zigsaw's token, not the new
  process's.

**[`tests/certs.sh`](../tests/certs.sh):**

- A new row deletes the file, has a soft run write it again, and reads it
  from an AppContainer: it fails with zigsaw 0.53.0, and passes now.
- Perl's two rows run script files: with `-e`, Perl opens `nul`, which an
  AppContainer on Server 2025 can't.
- CMake's, zig's and PHP's streams' AppContainer rows aren't gated any
  more (they passed on Server 2025), nor PHP's curl's, Composer's, Perl's
  and the file's, which failed there for the file. The JRE's
  (`java.nio.channels.ClosedChannelException`) and MinGit's still are.

**[`tests/gtk.sh`](../tests/gtk.sh):** libsoup's untrusted root is a
self-signed certificate made for the run, which Git Bash's `openssl
s_server` serves on `127.0.0.1`. The AppContainer row reaches it through the
loopback exemption. `SOUP_UNTRUSTED` still points it elsewhere.

### Slice 1: which sandbox a run gets (zigsaw 0.54.0)

- **`permissions.sandbox`** ([`src/oci.zig`](../src/oci.zig)): `soft`,
  `low` or `appcontainer`, absent unless an image asks, so no other
  image's config changes. The `Sandbox` type moved there from
  `override.zig`.
  - Asking for `soft` is access: `info`, `pull` and an install say
    "whatever you can write (it asks for the soft sandbox)", and an update
    that newly asks for it asks first.
  - A zigsaw before 0.54 ignores the field, as it does any it doesn't
    know, and runs the app under soft, its own default.
- **The store-wide overrides** ([`src/override.zig`](../src/override.zig),
  [`src/main.zig`](../src/main.zig)): `zigsaw override --global [options]`,
  `--global` alone to show them, `--global --reset` to remove them. They're
  `<store>\overrides.json`, as an app id needn't have a dot, so no name in
  `overrides\` is free. A change settles every app's grants, as an app's
  override does its own.
- **`override.sandboxOf`** decides: the settings' sandbox (command line
  over the app's overrides over the store-wide ones), else the image's,
  else low. Runs ([`src/run.zig`](../src/run.zig)) and what stands
  ([`src/grants.zig`](../src/grants.zig)) both use it, with the same
  layers (`override.loadFor`).

### Slice 2: low runs under the default

[`src/run.zig`](../src/run.zig):

- **A working directory low won't label** (your profile, a folder that
  holds it, a drive's root) stays read-only for the run, with
  `warning: <dir> is read-only for this run, as it's your user profile:
  run the app from a folder inside it to let it write there, or with
  --sandbox=soft`. A path granted with `--filesystem` there is still
  refused.
- **Grants inside the run's data directory are skipped**, low and
  AppContainer: a shortcut starts the app in its home, which was labelled,
  recorded and announced again as a working directory.
- **The data directory's first label** says so when it takes a second or
  more (an existing app's first low run, after an upgrade), or with `-v`.

**Recipes:**

- Kanboard's and Files' ask for `soft`.
- Xdebug's `.ini` sends traces and profiles to `${TEMP}`, the run's: its
  default, `C:\Windows\Temp`, can't be written at low integrity, so tracing
  and profiling failed under the new default (found by php.sh, below).
- The test apps of shims.sh (the GUI app writes where it's told), batch.sh
  (so that an injected command could write) and install.sh (`ping` fails
  at low integrity) ask for soft too.

### Slice 3: the suites under the new default

Rows that name no sandbox now run at low, as users' runs do:

- **The rows that ran only under soft now run at low**: TeX Live's XeLaTeX,
  Biber, latexmk, epstopdf and ps2pdf; PostgreSQL's first pass (TLS, ICU,
  dumps, backups, PostGIS's topology); Java's and GTK's builds with the
  SDKs' tools; Qt's SDK's cmake; PHP's extensions' own suites. Their
  explicit low rows became soft rows (gtk.sh, gtk3.sh, qt.sh, texlive.sh,
  postgresql.sh), so each sandbox is still covered.
- **What's about soft says so**: shims.sh's "writes anywhere" row is now
  "a soft override lets it", ctrlc.zig's plain `zigsaw run` is
  `--sandbox=soft` next to the default, sandbox.sh's held run and its
  folders' soft rows (the latter through `override --global`),
  osm2pgsql.sh's PostgreSQL server, 7-Zip's archive in guiapps.sh, and
  Xdebug's own test suite, which writes to `C:\Windows\Temp`.
- **Suites that ran apps from where they were started** (shims.sh,
  registry.sh, published.sh) run them from a scratch directory, and check
  that no run labelled the repository: a low run labels an app's working
  directory, and it stays labelled.
- **sandbox.sh** has 14 new rows: a plain run is low; from your profile and
  from a drive's root the working directory is read-only, with the
  warning; a run from the app's home labels nothing; an image that asks
  for soft says so and gets it, until the store-wide overrides choose
  another, under the app's own, under the command line; `--global`
  shows, resets, and settles grants; and `override` takes an app or
  `--global`, not both.
- **php.sh**: Xdebug writes a trace to the run's `TEMP` in each sandbox.

## Results

| check | result | time |
|---|---|---|
| Kanboard, fresh stores `D:\zs\i54\p` and `p2` | the same in both: manifest `89b5ce6b` (was `85fc1b8d`), layer `4b393eb0`, as published | 49 s |
| Xdebug 3.5.3, the same two stores | the same in both: manifest `db8e0ccb` (was `858338d5`), layer `8a33bf59` (new: the `.ini`) | 3 min 20 s |
| unit tests | 132 passed | |
| tests/sandbox.sh | 108 ok | 23 s |
| tests/shims.sh, store.sh, batch.sh, install.sh, ctrlc.sh, network.sh | 55, 16, 12, 15, 26, 26 ok | 4 min in all |
| `GROUP=base tests/build.sh` | 91 ok | 2 min 12 s |
| tests/self.sh | 15 ok: zigsaw 0.54.0 builds itself the same | 7 min 41 s |
| tests/registry.sh, against zigsaw's zot | 86 ok | 7 min 4 s |
| tests/matrix.sh (`D:\zs\a`) | 0 differ, 3 known gaps | 2 min 14 s |
| tests/certs.sh (`D:\zs\i53\p`), before the CA is trusted | 16 ok, the rewritten file's row too (which fails with 0.53.0) | 25 s |
| tests/texlive.sh (`D:\zs\i53\p`) | 0 failed, 1 known gap (pdfLaTeX in an AppContainer) | 5 min (beside other suites) |
| tests/postgresql.sh, osm2pgsql.sh (`D:\zs\i53\p`) | 0 failed, 0 gaps each | 93 s, 18 min (beside other suites) |
| tests/php.sh (`D:\zs\i53\p`) | 46 ok | 7 min 19 s |
| tests/java.sh (`D:\zs\i52\p`), gdal.sh (`D:\zs\i48\p`), zls.sh (`D:\zs\a`) | 44, 32, 19 ok; 0 failed | 10 min (its images rebuilt), 6.5 min, 75 s |
| tests/gtk.sh, gtk3.sh, qt.sh, guiapps.sh (`D:\zs\a`) | 100, 45, 39, 15 ok; 0 failed (guiapps 1 known gap) | 38, 34, 5, 1.6 min |
| every published app the matrix store has (60), run as published.sh's smoke does, with nothing on the command line | 60 ok | |
| scripts/check-pins.sh | 0 missing, 0 older runtimes | |
| the repository's ACL after all of it | no label, no AppContainer entry | |

The first qt.sh run, while Xdebug built in two stores, failed its six
Qt Quick rows under every sandbox, soft too, with no output; run again
alone it passed them all.

## Decisions made along the way

- **The relay is left as it is.** It looked like the same bug as the
  file of roots, but a program's own ACL isn't what starts it in a
  container.
- **The warning got shorter**: it's printed on every run of an app with
  `cwd` from your home folder, Node's in the README's quick start among
  them.
- **Xdebug's traces go to the run's `TEMP`** under every sandbox, where
  they were Windows' under soft: it's a one-line `.ini` change, which the
  plan's gate allowed without asking.
- **Test apps that write where they're told ask for soft** in their
  images, rather than through overrides: their suites are about shims,
  batch files and installing, not the sandbox, and it uses the new field.

## Known gaps

New in [gaps](gaps.md):

- under `low`, labels pile up: each directory an app with `cwd` ran in,
  and the folders apps may write, stay labelled, and any low-integrity
  program may write there;
- a working directory low won't label is read-only for the run;
- `zig fetch`, and so a `zig build` that has dependencies to fetch, fails
  under zig's default sandbox now (`zigsaw override --sandbox=soft
  org.ziglang.zig`);
- undeclared HKCU writes (Flameshot's "Launch at startup", Java
  preferences an image doesn't declare) fail by default now;
- System32's `ping` fails at low integrity;
- a zigsaw before 0.54 ignores `permissions.sandbox`.

## Next

- **Publish** from the store `D:\zs\i54\p`, which has both, with
  `ZIGSAW=D:\zs\i54\bin\zigsaw.exe` (0.54.0 as built here), **before
  pushing**:
  - `recipes/kanboard.json` (CI's published.sh pulls it, and its smoke
    run, now at low by default, needs the image that asks for soft);
  - `recipes/php-xdebug.json` (CI's apps group compares it).
- Then commit and push, and tag v0.54.0 (v0.53.0 was never tagged; this
  release has its `${roots}` and the fix of its file's ACL).
- Then I read the run. It checks every family: tests/published.sh changed.
  - certs.sh's AppContainer rows on Server 2025: psql, PHP's curl,
    Composer, Perl and the file of roots, which this fixes;
  - libsoup's rows against the local server;
  - every suite and published.sh's smoke runs at low.
