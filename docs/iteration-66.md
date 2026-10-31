# Iteration 66: deltas, Range downloads, and reading remote files

Built 2026-10-31 to 2026-11-01. zigsaw **0.66.0** and stargazer **0.2.0**:
a pull or update of an eStargz layer builds the new blob from the store's
blobs and fetches only the rest by Range requests; a download that breaks
off goes on from where it got to; `zigsaw ls` and `zigsaw cat` read an
image's files without pulling it. llvm-mingw's image moves to eStargz: one
image to publish. The design is [layer-formats.md](layer-formats.md).

## Outcome

- **Updates download what changed.** For a layer that has a per-file index
  (eStargz), zigsaw reads the new blob's tail (footer and TOC) with one
  Range request, plans it against the eStargz blobs the store has, copies
  the members they share, fetches the rest in at most 64 requests, and
  checks the blob it built against the manifest's digest, as a download
  is. A blob that doesn't match, a registry that won't send ranges, or a
  plan that would copy under a tenth: downloaded whole.
- **What that saves depends on what changed**:

  | update | blob | copied | fetched | requests |
  |---|---|---|---|---|
  | Qt's SDK, 3 files changed in place | 96.2 MB | 98.9% | 0.4% + 0.6 MB TOC | 3 |
  | llvm-mingw 20261006 → 20261020 | 110.3 MB | 16.5% | 83.5% | 14 |

  llvm-mingw's upgrade keeps 5,115 of its 5,382 files, but they're mostly
  headers: 17% of the bytes. Every program and Clang's runtime libraries
  change between releases. The plan copies everything the two TOCs share
  (18.96 MB; the files with unchanged digests are 18.97 MB compressed), so
  the matching isn't what limits it. Through local zot the update took
  575 ms against 478 for the whole download: with no bandwidth limit,
  bytes saved don't show as time.
- **A broken download resumes**, by a `Range: bytes=N-` request, up to 5
  times as long as each attempt got further, into the same file and the same
  sha256. A registry that answers with the whole blob is asked for it once
  more from the start.
- **`zigsaw ls` and `zigsaw cat`**: Qt's runtime on ghcr.io (1,977 files)
  listed in 2.9 s with one 1 MiB request through ghcr.io's redirect to its
  storage; a 10 KB DLL of it read in two requests, the same bytes as the
  deployed file. The store keeps only the image's config.
- **llvm-mingw on eStargz**: the same files, 110.3 MB instead of 107.6
  (+2.5%), byte for byte `stargazer convert` of the published gzip layer,
  and the same manifest (69f40e5c) built in two fresh stores. Its 11
  consumers keep their pins of the gzip builds.
- **Git Bash pipes crashed big writes to stdout**: Zig 0.17 takes the
  standard handles for synchronous ones, and MSYS's pipes aren't, so a write
  that had to wait for a full pipe hit `unreachable` in std
  (`.PENDING => unreachable // wrong File nonblocking flag`). `info` and
  `list` never filled one; `cat` did. Fixed for `ls` and `cat` (below).

## Starting decisions

From the plan, the same day:

- Yours: **resume within one run** (nothing partial outlives the command);
  **`zigsaw ls` and `zigsaw cat`** as commands, not `info` flags; **one big
  SDK on eStargz, llvm-mingw**, with a real upgrade measured.
- Mine: planning in stargazer (Zig only), the HTTP, store and digest checks
  in zigsaw; the pool is every eStargz layer of every image the store keeps;
  a reused member is a strong guess and the manifest's digest decides;
  coalesced single ranges, no multi-range requests; under 10% reuse, whole.

Decided during (mine):

- **The tail scales with the blob**: 1/64 of it, between 16 KiB and 1 MiB.
  A fixed 1 MiB was the whole of a small blob, so a busybox-sized update
  saved nothing. TOCs run some 60 bytes per file compressed (llvm-mingw's
  348 KB for 5,551 entries); a longer one costs a second request.
- **Gaps up to 64 KiB are fetched**, as well as the shortest gaps beyond 64
  requests: another round trip costs more than 64 KiB. llvm-mingw's plan
  goes from 73 raw fetches to 14 requests for 0.7% more bytes (16.5% copied
  instead of 17.2%).
- **The lead member counts like the others**: the landmark's header,
  copied when the old blob's lead has the same length and the first entries
  are the same, so an unchanged blob needs only its tail.
- **A file's last member is keyed by what follows it** in the TOC up to the
  next payload (name, type, size, mode, ids, names, times, link, device,
  xattrs), with user and group names carried forward, as the TOC gives a
  name only when it changes. A rename after a file refetches that file's
  member, not the renamed one's (a test pins this).
- **`Context.stdout()`** asks Windows whether the handle does synchronous
  I/O (`NtQueryInformationFile`, `FileModeInformation`) and, if not, gives
  std the nonblocking flag, whose path waits. Only `ls` and `cat` use it so
  far; a reader that stops (`| head`) ends them quietly.
- **No delta estimate in `info` or the install consent** yet: it would cost
  the Range requests before asking.

## What was built

### stargazer 0.2.0

- `src/plan.zig`: `members` (every member of a blob, the lead and the TOC
  included, each with a key of what another must match), `make` (pieces
  covering the new blob: copy from an old blob, or fetch), `Plan.coalesce`,
  `copied`/`fetched`/`requests`, and `apply`, which builds the blob from
  `Source`s. Tests: unchanged files copied and changed ones fetched, a
  renamed or re-moded next entry, several old blobs, coalescing pinned, and
  random edits (a fixed seed here, a fuzz target on Linux) whose built blob
  must always be the new one.
- `stargazer plan [--max-requests=] [--min-gap=] <old>... <new>`.
- README: the plan API, version 0.2.0. The C ABI is unchanged.

### zigsaw

- `src/Registry.zig`: `getBlob(digest, span, sink)` streams a blob or a
  span (Range request, 206 checked by its Content-Range) and resumes a
  break from the byte it got to; a counting "hasher" over std's
  `Writer.hashed` knows how many bytes arrived. A 200 to a Range request
  isn't read (error.RangeIgnored). Downloads go through it;
  `ZIGSAW_TEST_DOWNLOAD_BREAK=<bytes>` breaks the first transfer longer than
  that, once.
- `src/RemoteBlob.zig`: a blob as a stargazer `Source`, from the store's
  file or by Range requests, with the tail cached.
- `src/format.zig`: `Format.indexed()`, `Index`, `openIndex` (the TOC
  checked against the descriptor, as the deploy path did), `isLayerFile`,
  and stargazer's `plan`.
- `src/remote.zig`: `downloadByPlan` before a whole download;
  `indexedLayers` (the pool); `fetchInfoOpen`.
- `src/peek.zig`: `zigsaw ls` and `zigsaw cat`.
- `src/Context.zig`, `src/win32.zig`: `stdout()` and `synchronousIo`.
- recipes/llvm-mingw.json: `"layer": "estargz"`.
- README, docs/recipes.md, docs/layer-formats.md.

### Tests

- tests/registry.sh, 11 new rows: `ls`, `cat` (the source's sha256) and a
  store left with the config only; `cat` of a gzip image refused by name;
  an update to a version 2 that adds a file, fetching under a quarter of
  the layer, the same image as a fresh build, deployed with the new file;
  the same update over a damaged old blob, refused after building and then
  downloaded whole; a download broken at 100,000 bytes and resumed; `cat`
  of a Qt file from ghcr.io.

## Results

- stargazer: `zig build test` 24/24, `test-c` ok, `zig fmt` clean.
- zigsaw: unit tests 144/144; tests/registry.sh 102 ok (through
  tests/zot.sh); tests/self.sh 15 ok (zigsaw builds itself byte-identical,
  10 min); tests/store.sh 16 ok.
- llvm-mingw 20261020 (eStargz): manifest 69f40e5c, layer c858bd90, in
  `D:\zs\i66\p` and `D:\zs\i66\p2`; a 20261006 build (local only) for the
  measurement, script `D:\zs\i66\delta.sh`.
- Defender: zigsaw, the shims, the relay and stargazer clean.
- check-pins: 0 missing (nothing pins the new llvm-mingw yet).

## Next

- **Commit and push stargazer first** (0.2.0: plan.zig, CLI, README), and
  I read its CI: the new fuzz target runs in the fuzz job.
- **Publish llvm-mingw before pushing zigsaw** (CI's llvm group compares
  its build with ghcr.io), from the store that built it:
  `ZIGSAW_HOME='D:\zs\i66\p' ZIGSAW='D:\zs\i66\bin\zigsaw.exe' scripts/publish.sh llvm-mingw.json`.
  Then check-pins may warn that the Qt and GTK SDKs carry an older
  llvm-mingw runtime: expected, the same files.
- Then commit zigsaw with the submodule pointer, push, and I read the
  Reproduce run (llvm group, suites with registry.sh's new rows).
- Tag **v0.66.0** after the push.
- Later: a delta estimate in `info`; parallel ranges within one blob;
  `Context.stdout()` for every command that writes much; zstd:chunked when
  Zig can compress zstd.
