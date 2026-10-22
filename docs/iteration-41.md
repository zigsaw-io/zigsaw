# Iteration 41: Qt on any Windows, grants that last as long as they should, and registries as Docker's

Built 2026-10-22. zigsaw 0.41.0. No image changes: nothing to republish.

## Outcome

- **Iteration 40's run** (7a27ab8) was red only in the `qt-base` and `qt`
  groups. Both Qt SDK halves install `modules/*.json` files that record the
  Windows version CMake ran on: `10.0.26300` here, `10.0.26100` on the
  Server 2025 runner. Nothing else differed. Every Qt module now passes
  `-DCMAKE_SYSTEM_VERSION=10.0.26300`, the value the halves were published
  with, so a runner builds the published bytes. The Qt jobs' timeout is 120
  minutes, as the `qt` job took 77 of its 90.
- **What a run is granted on host paths lasts as long as something gives
  it** ([how long grants last](../README.md#how-long-grants-last)):
  - Under `low` and `appcontainer`, a label or ACL entry stays only while a
    run with nothing on its command line would make it again: under the
    app's saved sandbox, for the paths and folders its permissions and
    overrides name, and for its working directories while it keeps `cwd`.
  - `--file`, a command-line `--filesystem` or `--sandbox`: taken back when
    the app's last run ends, so a run that hands its file to another
    instance leaves that instance able to save it.
  - A permission or override that goes takes its grant with it: at once
    from `zigsaw override` or an install, or when the app's last run ends.
  - `zigsaw repair` settles what earlier zigsaws kept until `rm`.
- **Registries as Docker uses them:**
  - **Multi-platform indexes:** `pull`, `update` and `info` take an index's
    image for `windows/amd64`; an index without one is refused, naming the
    platforms it has.
  - **Docker's logins:** after the environment's and zigsaw's own, the login
    `docker login` saved, from a credential helper (`credHelpers`,
    `credsStore`) or from `config.json` itself.
  - **Uploads in chunks:** blobs over 64 MiB go up in chunks
    (`ZIGSAW_UPLOAD_CHUNK_SIZE`), and one that breaks off goes on, or starts
    again when the registry has dropped it, as zot does. A registry that
    refuses chunks gets the blob in one request, as before.

## Starting decisions

Made with you at planning (plan:
`C:\Users\Test\.claude\plans\let-s-address-some-gaps-async-reef.md`):

- **Qt:** pin the published version value rather than a generic `10.0`, so
  nothing is republished.
- **Gaps to close:** stale grants, and registry compatibility (indexes,
  Docker's logins, chunked uploads). Not install consent; the Temurin
  re-pin stays a session of its own.
- **cwd grants stay while the app keeps `cwd`**, rather than only the
  latest or only during the run: granting a big project takes a while.
- **The saved sandbox decides what stays**: a sandbox given only on the
  command line grants afresh on each run.

## What was built

### Qt's system version

- `recipes/qt6-sdk-base.json` and `recipes/qt6-sdk.json`: the flag on all
  seven `cmake -S . -B out` lines. Build commands aren't in an image's
  config, so the digests stay.
- Checked first: qtbase uses `CMAKE_SYSTEM_VERSION` only for that JSON and,
  when cross-compiling, its toolchain file. CMake keeps a given version
  without `CMAKE_SYSTEM_NAME`, and doesn't cross-compile then (a probe with
  CMake's image printed `10.0.11111`, host `10.0.26300`, `FALSE`).
- No local rebuild: here the flag changes nothing, and the runner's builds
  differed only in that field. The next run is the proof.

### Grant lifetimes

- **[`src/grants.zig`](../src/grants.zig)** (new):
  - `begin` and `end`: every run holds `grants\<id>.txt.lock` shared; the
    run that can lock it exclusively at its end is the last, and settles,
    as `hkcu.zig` does for registry keys.
  - `settle` works out what stands (`Standing`: the saved sandbox, the
    paths and folders, and `cwd`), keeps that, and takes back the rest.
  - Kept AppContainer grants lose the app's package SID's access (from
    before iteration 9), and write access where the app may now only read.
  - `undoAll` is `rm`'s, moved there.
- **`grants\<id>.cwd`** lists which grants were a run's working directory;
  a separate file, so an older zigsaw's `rm` still reads `.txt` as before.
- **`<root>\grants.lock`** is held while host ACLs or grants files change:
  as a run grants paths, as grants are taken back, by `rm`. This also ends
  a race in which two runs of one app could lose a recorded grant.
- **Where settling happens:** the end of the last run; `zigsaw override`
  (or a note that it waits for the app's runs); every install; `zigsaw
  repair`, for every app and for grants files of apps no longer installed.
  `prune` deletes the lock files of apps with nothing recorded.
- Messages say only what changed: `revoked … access to …`, `removed the
  low integrity label of … (N ms)`.

### Multi-platform indexes

- `remote.resolveImage` takes the first `windows/amd64` entry of an OCI
  index or Docker manifest list, checks its digest, and compares an
  installed digest before fetching it, so `update` stays one request. A
  `@sha256:` names what it fetches first, index or image.
- `info` shows the index; a recipe pin that names an index fails, giving
  the image's digest to pin.

### Docker's logins

- `credentials.lookup` goes on to Docker's config (`%DOCKER_CONFIG%` or
  `%USERPROFILE%\.docker`), in Docker's order: the registry's helper, the
  helper for all, then `auths` (`auth` or `username` and `password`).
- Helpers run through a new `process.output`: the registry on stdin, a
  30-second limit, stdout read after it ends. It puts back zigsaw's Ctrl+C,
  which starting a child turns off.
- A Docker login the registry refuses on a pull with a token service is
  dropped, with a note; `zigsaw login` and the environment's still fail.

### Chunked uploads

- `Registry.finishUpload` sends blobs over the chunk size as PATCHes with
  `Content-Range`, following each answer's Location and Range, then a PUT
  that names the blob.
- A chunk that breaks off, or that the registry fails, asks the registry
  how much it has (waiting while it answers 5xx) and goes on from there, at
  most three times; a registry that doesn't know the upload any more gets
  the blob again in a fresh one.
- Fixed on the way: a request whose body broke off left its connection in
  the pool, half written (Zig 0.16 marks it closing only once a response
  has arrived); and a token refused mid-push is now asked for again, once.
- `ZIGSAW_TEST_UPLOAD_BREAK=<n>` breaks the nth chunk off halfway, for
  tests.

### Tests and docs

- **`tests/sandbox.sh`** reworked:
  - Grants from a run's command line are checked from inside the run
    (`icacls` in it), and gone after it.
  - A held run keeps a `--file` grant past a second run's end.
  - A killed run's label is taken back by the app's next run.
  - A third app's saved overrides check standing grants, `override
    --nofilesystem` and `--reset` (also while a run goes on), the switch from
    low to AppContainer, a path becoming `:ro`, and two working directories.
  - Folders: a low override's label stays and goes with `--nofilesystem`;
    an update without the permission takes the AppContainer grant back.
- **`tests/shims.sh`**: a file opened from Explorer under low is unlabelled
  after its run.
- **`tests/registry.sh`**:
  - pushes in chunks, a chunk that breaks off, and Node in 16 MiB chunks;
  - indexes made with curl;
  - Docker logins through a `DOCKER_CONFIG` of its own and a fake helper,
    [`tests/credhelper.zig`](../tests/credhelper.zig) (`zig build
    cred-helper`).
- **Docs:**
  - README: how long grants last, indexes, chunks and Docker's logins.
  - gaps.md: the grant entries rewritten, and the three registry entries
    replaced by what's still open.
  - recipes.md: Qt's flag.
  - `zigsaw help`.

## Results

| check | result | time |
|---|---|---|
| iteration 40's run, files-diff of both Qt halves | only `modules/*.json`'s `"version"` differed (23 and 74 files) | |
| CMake probe: `-DCMAKE_SYSTEM_VERSION=10.0.11111` | kept, host's 26300, not cross-compiling | seconds |
| unit tests (`zig build test`) | 111 passed | 1 s |
| grants probe: a `--file` run while another run goes on | labelled after its run, unlabelled after the other's | seconds |
| `tests/sandbox.sh` | 94, 0 failed | 26 s |
| `tests/shims.sh`, `tests/store.sh`, `tests/ctrlc.sh` | 54, 15, 26; 0 failed | 6 min |
| `tests/matrix.sh` (matrix store) | 0 differ from the intended; the 3 known AppContainer gaps | 2 min |
| `tests/registry.sh` through `tests/zot.sh` | 73, 0 failed | 2 min |
| chunk probe against zot: a break at chunk 1 and at 3 | zot drops the upload (500, then 404); the blob goes again, and the push succeeds | seconds |

Not rerun here: `tests/build.sh` (builds don't use grants), and the GTK, Qt,
Java and PHP suites, which need their stores and open windows. Their runs
now take back what their command lines grant; their only checks of host
ACLs are that nothing stays labelled or granted, which holds the more. CI
runs them (GTK's weekly), and its `qt-base` and `qt` groups check the Qt fix.

## Decisions made along the way

All my calls:

- **The runs' lock is never deleted while it matters.** hkcu deletes its
  lock under a named mutex; grants keep `grants\<id>.txt.lock`, and `prune`
  deletes it once nothing is recorded, as it does deployments' locks.
- **`rm` prints only what changed**, as settling does; it printed every
  recorded path before.
- **sandbox.sh looks from inside a run** to check what a command line
  grants, rather than through saved overrides, so both lifetimes are
  checked.
- **Zot drops an upload that broke off** (it answers 500, then 404), so
  resuming from its Range can't be seen against it. A registry that can't
  say how much it has gets the blob again, from the start, in a fresh
  upload; only 5xx answers are waited out.
- **Node goes up in 16 MiB chunks in the test:** its layer is 38 MB, below
  the 64 MiB default.
- **Docker's credential helpers are run as `.exe` only**, from PATH, as
  Docker Desktop installs them.

## Known gaps

- Each working directory of an app with `cwd` stays granted, under its
  saved sandbox, until the app loses `cwd`; a sandbox given only on the
  command line pays for granting a big folder on every run.
- A run that zigsaw didn't see end leaves its grants until the app's next
  run ends, `repair` or `rm`. Two stores don't know each other's labels.
- Resuming an upload from the registry's Range is untested against a
  registry that keeps a broken upload; zot gets the blob again instead.
- No identity tokens from Docker; no index pushes; nested indexes refused.

## A slip of mine

My first sandbox.sh run seeded its temporary store, on C:'s TEMP, from
`D:\zs\a`'s whole download cache: hard links fail across drives, so it
copied 8.6 GB and filled C:. The script stopped before its cleanup; I
deleted the two directories it had made (nothing was installed in them),
and C: is back to the 8.6 GB it had free. Runs since use `TMPDIR` on D: and
a seed of only the downloads the suites need.

## For you

1. Commit and push. The `qt-base` and `qt` groups must build `c3df032b` and
   `7361e491` on the runner now; nothing needs publishing first.
2. Before relying on chunks with ghcr.io: push one big image (Node's layer
   is 38 MB, so with `ZIGSAW_UPLOAD_CHUNK_SIZE=16777216`) to a scratch
   repository of yours with `-v`, and see `sent … in 3 chunks`, or the note
   that ghcr.io doesn't take chunks and the blob went in one request.
3. Tag v0.41.0.
4. `zigsaw repair` after installing 0.41.0 takes back what older versions
   kept granted until `rm`: expect a list of `revoked` and `removed` lines
   the first time.

## Suggested for iteration 42

- The Temurin re-pin: 25.0.5+8 is GA now; the eight Java images are on
  25.0.5+7 early access.
- Install consent: `pull` and `update` asking before they go on.
- The parallel-make wrapper for Gnumeric and goffice; Qt's CI time.
