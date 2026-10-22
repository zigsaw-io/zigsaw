# Iteration 42: Workaround zig hanging on a console, and Qt Quick in half the time

Built 2026-10-23. zigsaw 0.42.0. Four images to republish: Qt's SDK and
runtime, Flameshot and Notes.

## Outcome

- **Iteration 41's run** (2d7360b) was red only in gtk-suites:
  `tests/gtk3.sh` compared three runs' output with zigsaw's new notes in
  it. A run's end no longer says it kept a label other apps need (only `rm`
  and `-v` do), and the suite leaves out the notes of what a run took back.
- **The `qt` job had 5 seconds to spare**: 1h59m55s of its 120. It built
  what iteration 40's run had built, but every command took half as long
  again: qtdeclarative's build 47m38s → 1h15m, its second pass 11m23s →
  17m16s, qttools 7m58s → 12m22s. The base half, on another runner, went
  the other way (49 → 34 minutes). Runners differ that much, so the Qt jobs'
  timeout is 180 minutes now.
- **Qt's SDK builds in 26 minutes here, not 48**, and the runtime is 153 MB
  deployed, not 163:
  - qtdeclarative is a **unity build**, which took its build from 31m35s
    to 14m14s, and its second pass from 7m27s to 2m27s.
  - **Quick Controls has no Imagine style and no Qt Labs StyleKit.** It
    keeps the styles Windows uses (Basic, Fusion, Windows, FluentWinUI3)
    and Material and Universal, which Notes imports.
  - Everything reproduces: the SDK, runtime, Flameshot and Notes have the
    same digests in two fresh stores.
- **Chunked uploads now cope with ghcr.io.** Publishing the SDK failed: in
  iteration 41's chunks, ghcr.io failed a chunk of its 87 MB layer, and
  couldn't say how much it had, so zigsaw started the chunks again, three
  times, and gave up. A registry that fails a chunk and can't say now gets
  the blob in one request, as ghcr.io always took them.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\let-s-plan-iteration-42-vast-tome.md`):

- **Trim Qt's build**, over install consent (later) and parallel make for
  GTK's autotools builds.
- **Imagine and StyleKit only.** Notes uses Material (19 of its QML files)
  and Universal (8). The QML debugging and profiling plugins stay.
- **A unity build for qtdeclarative, probe-gated**: kept only if the SDK
  reproduced in two fresh stores and qt.sh passed, and if it cut
  qtdeclarative's main build to about 22 minutes or less.

## What was built

### A green run

- **[`src/grants.zig`](../src/grants.zig)**: `undo` says it kept another
  app's label only when asked to: `rm` asks (`tests/sandbox.sh` checks
  that note), and a run's end does under `-v`. Iteration 41 meant notes to
  say only what changed; this one didn't.
- **`tests/gtk3.sh`**: `python_says` also leaves out `revoked …` and
  `removed the low integrity label …`, as it did `granted` and `labelled`.
  On the runner, another app's grants still named the suite's work folder,
  so the first row got the "kept" note; the others got the notes of what
  their command line had granted being taken back.
- **[`reproduce.yml`](../.github/workflows/reproduce.yml)**: the `qt-base`
  and `qt` jobs' timeout is 180 minutes, with iteration 41's times in the
  comment.
- **Version 0.42.0**, which also has bd5b678's `ZIG_PROGRESS=off` for
  build commands (zig hanging on a console).

### Qt's SDK, leaner and faster

[`recipes/qt6-sdk.json`](../recipes/qt6-sdk.json)'s qtdeclarative module
configures with three more flags:

- **`-DFEATURE_quickcontrols2_imagine=OFF`,
  `-DFEATURE_quickcontrols2_stylekit=OFF`.**
  - In iteration 40's build tree, Imagine took 3.8% of qtdeclarative's CPU
    time and StyleKit 4.5%; together they are 9 MB of the runtime.
  - Windows' styles depend on each other: Fusion, Windows and FluentWinUI3
    all need Basic.
- **`-DQT_UNITY_BUILD=ON`**: CMake compiles qtdeclarative's C++ files 32 to
  a file, so Qt's headers are parsed once a batch.
  - It's Qt's own option (`QT_UNITY_BUILD`, from the base half's CMake
    files, whose cached `OFF` a `-D` overrides), and Qt's CI builds that way.
  - It compiled with zig at the first try: no file had to be left out of
    its batch.
  - Ninja's log has one build at 258 minutes of CPU time, against 712 in
    iteration 40, and qmlcache's share at 23 minutes against 160. The
    compiled QML is now mostly in the batches.
  - The wall time fell less (31.6 → 14.2 minutes), as fewer, longer jobs
    leave CPUs idle at the end.
- **The second pass still works**: it deletes the generated QML C++ and
  builds again, and the SDK came out the same in both fresh stores (in
  iteration 40, without that pass, the FluentWinUI3 style's DLL differed).
- **The base half doesn't change**, nor do qttools and qttranslations.

The runtime, Flameshot and Notes are re-pinned to the new SDK (and Flameshot
and Notes to the new runtime). Flameshot's and Notes' own layers are the
bytes they had: only their configs change.

### Chunks that ghcr.io fails

Your publish of the SDK said, three times, `upload of sha256:64ab186c05b2
broke off (the registry failed), and ghcr.io can't say how much of it it
has (HTTP 404); starting it again`, and gave up. "The registry failed"
meant that nothing broke off: ghcr.io answered a chunk with an error, an
HTTP 416 or 5xx, which the message didn't show, and then 404 when asked how
much it had. Iteration 41 handled that as zot losing an upload that broke
off, by starting the chunks again; iteration 41's suggestion to try a big
push to ghcr.io first would have found it.

[`src/Registry.zig`](../src/Registry.zig), `putChunks`:

- **A failed chunk the registry can't account for** sends the blob in one
  request, in a fresh upload, and every later blob of the push goes in one
  request too (`no_chunks`). Before, only a refused first chunk did.
- **An upload the registry lost** (404 for a chunk or for the closing PUT)
  goes again from the start, in chunks, if it broke off before, and
  otherwise in one request. zot drops an upload that broke off a moment
  after it may still have said how much it had: 2 pushes in 16 of the
  broken-chunk test failed on that, with `not found` (in iteration 41's
  code too).
- **Messages name the HTTP status** (`failed (HTTP 416)`), and `-v` prints
  each chunk's answer and Range.
- **Test hooks** for registry.sh, beside `ZIGSAW_TEST_UPLOAD_BREAK`:
  - `ZIGSAW_TEST_UPLOAD_SKIP=<n>`: chunk n claims to start a byte late, which
    zot really answers with 416.
  - `ZIGSAW_TEST_UPLOAD_LOST`: the question of how much it has goes to an
    upload zot doesn't know, which it answers with 404.
  - `ZIGSAW_TEST_UPLOAD_LOSE=<n>`: chunk n goes to such an upload.

What ghcr.io answered the chunk with isn't known: the old message hid it.
The next push there with `-v` shows it.

### Tests and docs

- **`tests/registry.sh`**: four checks, against zot:
  - a chunk zot fails (416) goes on from where zot says it got to;
  - with zot unable to say, the blob goes in one request;
  - an upload zot lost after a break goes again in chunks;
  - one it lost otherwise goes in one request.
- **`tests/qt.sh`**: a check that the runtime's QML has the six styles, and
  neither `QtQuick/Controls/Imagine` nor `Qt/labs/StyleKit`. Notes' row
  "its QML loads without errors" already shows that Material and Universal
  load.
- By hand, with the runtime's `qml` tool on a Controls window
  (`QT_QUICK_CONTROLS_STYLE`):
  - Imagine fails with `module "QtQuick.Controls.Imagine" is not
    installed`.
  - Material, Universal and FluentWinUI3 draw it.
- **Docs:**
  - recipes.md: Qt's section has the styles, the unity build, and the new
    times and sizes.
  - gaps.md: the Qt family entry, the runtime's size, CI's Qt times and
    timeout, and chunks on ghcr.io.
  - README: what happens to chunks a registry fails.
  - `scripts/published-groups.txt`: Qt's times.

## Results

| check | result | time |
|---|---|---|
| unit tests (`zig build test`) | 111 passed | 9 s |
| `tests/sandbox.sh` | 94, 0 failed | 19 s |
| `tests/gtk3.sh` (pulled GTK store) | 45, 0 failed, the three rows of iteration 41's run included | 3 min |
| `[qtdeclarative 2/5]`, fresh store p / p2 | 14m14s / 13m56s (31m35s and 31m14s in iteration 40) | |
| `[qtdeclarative 4/5]`, the second pass | 2m27s / 2m26s (7m27s, 7m32s) | |
| SDK on the published base, p / p2 | 26m16s / 26m42s (47m58s, 47m57s) | |
| io.qt.Qt6.Sdk in p and p2 | `e71f8733` in both; layer 87.5 MB (90.5 before) | |
| io.qt.Qt6 in p and p2 | `1b2c095a` in both; 153 MB deployed, 55.6 MB compressed (163, 58.9) | 24–42 s |
| org.flameshot.Flameshot in p and p2 | `e75b1b76` in both; own layer `7b985908`, unchanged | 2–4 min |
| io.github.nuttyartist.notes in p and p2 | `d42ee2dd` in both; own layer `0c3e5335`, unchanged | 1–4 min |
| the old pins, with zigsaw 0.42.0 | runtime `c09a8cfe`, Flameshot `ad06793e`, Notes `5fd7a5d0`: the published ones | |
| `tests/qt.sh` (store p) | 39, 0 failed | 5.5 min |
| `scripts/check-pins.sh` | only the 5 pins of the new SDK and runtime missing, until you publish | 1 min |
| broken-chunk push against zot, before the fix | 2 of 16 failed: `not found` after resuming | |
| the same after it | 40 of 40 pushed (15 with the final code) | |
| `tests/registry.sh` through `tests/zot.sh` | 77, 0 failed (73 + 4) | 2.7 min |
| icacls of the repo, Documents, Pictures | no label or AppContainer entry | |

Not rerun here: the suites the grants note can't reach (the matrix,
shims.sh, the GTK 4, Java and PHP suites). Of the published groups, CI
builds only Qt's on the push, since only Qt's recipes changed, besides the
weekly run.

On a runner, the SDK half should take some 40 to 65 minutes now, if
runners stay 1.5 to 2.4 times slower than this machine. The run will say.

## Decisions made along the way

All my calls:

- **The timeout stays at 180** after the unity build: a slow runner made 77
  minutes into 120, and the next run's time is still to be seen.
- **Only qtdeclarative is a unity build.** qttools (8 to 12 minutes on a
  runner) could follow, and qtbase, but that would be republishing the base
  half too.
- **qt.sh checks the styles by their files**, in seconds; the `qml` tool's
  answer to a missing style was checked by hand.

## Known gaps

- No Imagine style or Qt Labs StyleKit (gaps.md). An app that names one
  can't run on this runtime.
- How long the SDK takes on a runner now hasn't been seen.

## A slip of mine

`D:\zs\i42\qt\chain.sh` builds every step from the one it's given, which I
forgot when I started the runtime and apps in store p while the first chain,
started at the SDK, was still going on to them with the old pins. For a few
minutes two chains built in one store; zigsaw ran their builds one at a time
(`waiting for another zigsaw build to finish with B:`), and the store's refs
and the recipes' pins ended on the new images, as checked before the second
store's builds. It cost about eight minutes of builds, and showed that this
zigsaw still builds the published runtime, Flameshot and Notes byte for byte
from their old pins.

## For you

1. Publish the four images, in this order, from `D:\zs\i42\qt\p`, the store
   that has them. No new packages, so nothing to make public. Either:
   - with the fix: `ZIGSAW_HOME='D:\zs\i42\qt\p' bash scripts/publish.sh
     recipes/qt6-sdk.json recipes/qt6.json recipes/flameshot.json
     recipes/notes.json`. The build cache keys on zigsaw's exe, so the new
     one builds the four again there first (about 30 minutes, the same
     digests). The SDK's layer should then go up in one request once
     ghcr.io fails a chunk, after `ghcr.io failed a chunk of …`.
   - or at once, as before iteration 41: the same with
     `ZIGSAW='D:\zs\i42\qt\bin\zigsaw.exe' ZIGSAW_UPLOAD_CHUNK_SIZE=0` in
     front. That zigsaw built the store's images, so nothing builds again,
     and every blob goes in one request.
2. If you'd like to see what ghcr.io answers a chunk with (and you took the
   second way): `ZIGSAW_HOME='D:\zs\i42\qt\p' zig-out\bin\zigsaw.exe -v push
   io.qt.Qt6.Sdk ghcr.io/<you>/zigsaw-chunk-test:1`, then delete that
   package. Its `chunk 1 of …` lines say.
3. Then commit and push (bd5b678 goes with it). The Qt groups run, as their
   recipes changed: they check the new digests on a runner, and the SDK's
   time there. I'll then read the run.
4. Tag v0.42.0: v0.41.0 was never tagged, as v0.35.0 wasn't.

## Suggested for iteration 43

- Install consent: `pull` and `update` asking before they go on.
- The Temurin re-pin, once 25.0.5+8 has Windows builds (today it has only
  macOS and Linux ones).
- Unity builds for qttools, and for qtbase with the base half's next
  republish; then a shorter Qt timeout.
- The parallel-make wrapper for Gnumeric and goffice.
