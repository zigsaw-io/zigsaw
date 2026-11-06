# Iteration 78: Lazy pulling that pays

Started 2026-11-06. [Iteration 77](iteration-77.md) built `zigsaw pull --lazy`, and measured that
it saved little or cost time. This iteration finds where the time went and takes it back. zigsaw is
**0.78.0**, and stargazer **0.4.0**. Qt's chain is re-pinned and has prefetch lists, so there are
five images to publish.

It started with what 77 left:
- **Reproduce was red** (run 42186532585) on two rows of `tests/lazy.sh`. On GitHub's runner, a
  job refuses breakaway, so a helper started again says so on stderr. The two rows compared stderr
  with what they expected. That was the test's fault, not zigsaw's. Inside `zigsaw-jobprobe injob`,
  which makes such a job, the same two rows failed here, and none did once they compared stdout.
- **Release v0.77.0**: its six programs are the bytes of 77's table.
- **Other checks**: TeX Live `99b0c1d4` is on ghcr.io, stargazer 0.3 is pushed, and the probe's
  standard-user rows pass (run 42183523707).
- **Still owed**: `SHA256SUMS.sig` of v0.77.0.

## Outcome

- **`--lazy` is now faster than a full pull** for llvm-mingw, Qt's SDK, VSCodium and TeX Live. It
  ties for Designer, which reads most of Qt's runtime. See [Results](#results).
- **A helper fetches in parallel, and once**:
  - Every byte it fetches goes into one sparse file, with a map of its 1 MiB blocks.
  - A fetch asks at once for all its chunks' blocks that nobody has asked for. Each run of them is
    one Range request, on four threads with a registry client each.
  - The download skips what runs fetched, and a helper started again goes on from the map.
- **The download waits** for the pull, and for a run's fetches. Before, it took three connections
  from the start, and slowed TeX Live's pull of its gzip runtimes to half speed.
- **Installing reads its programs' headers at once**, into memory, so neighbours share a request.
  TeX Live has 150 commands.
- **A recipe can say what a first run reads**:
  - `"prefetch"` puts those files first in an eStargz layer, then the prefetch landmark, as Go's
    builder lays them out (stargazer 0.4.0, `convertSource`).
  - A lazy pull's helper asks for them all as soon as it starts, and has Windows hydrate each as its
    bytes come in.
  - `scripts/record-prefetch.sh` makes the list from a run of the published image.
- **Qt's chain is re-pinned to llvm-mingw's eStargz build**, and has lists:
  - Qt's runtime lists 36 files, which Designer's window reads.
  - Its SDK lists 456 files, which a CMake configure and build of a Qt program reads.
  - The five images reproduce in two stores: `9b87aa9a`, `965dba80`, `4a6ae197`, `9eb2702e`,
    `c3b76242`.
- **Keeping the placeholders' files at the swap doesn't pay**, as the probe showed. The swap stays a
  rename (gaps.md).

## Decisions

Yours:

- **Theme**: lazy pulling that pays, over a toolchain round, refusing unsigned images, and rollbacks
  that restore data.
- **Prefetch lists**: eStargz's prioritized files in the layer, from a recipe field that a script
  fills.
- **Republishing**: only Qt's re-pin chain, so only Qt's recipes have lists. llvm-mingw, VSCodium and
  TeX Live keep their bytes.
- **The in-place swap**: probe it first, and build it only if the result is indistinguishable.

Mine, say if you disagree:

- **A `prefetch` path the app doesn't have is left out, with a warning**, as Go's builder does, so
  that a version bump builds before its list is recorded again.
- **The download waits for the pull** (`lazy\<hex>.pull.lock`, held by the pull until it ends).
  It also starts nothing while a run is fetching, or for a second after.
- **Prioritized files come at a run's priority** from the helper's start, ahead of the pull's other
  layers. They are what the first run waits for.
- **The pull's header reads keep blocks in memory**, rather than share the helper's file across two
  processes.
- **The recorder ignores an image's own list** (`ZIGSAW_TEST_LAZY_NO_HYDRATE`), so that what a run
  reads is what it fetches.
- **Qt's SDK list is in its recipe**, 456 paths long, rather than in a file beside it. That's more
  than the 300 I said I'd flag: say if you'd rather have the file.
- **Not built: the in-place swap**, nor reading the new files after a rename swap. Neither made the
  next run warm.

## Results

| What | Result |
|---|---|
| `tests/lazy.sh` | 27 ok in 22 s, inside a no-breakaway job too |
| Unit tests | 171 in zigsaw's main binary, 186 in all four (5 for the blob reader, 1 for `prefetch`); stargazer 28, its C test, Go conformance with a prioritized blob |
| `registry`, `store`, `rollback`, `updates`, `signing`, `oci` | 113, 17, 32, 42, 34, 35 ok |
| `sandbox`, `shims`, `install`, `build` base group | 142, 55, 45, 92 ok |
| `tests/qt.sh` on the new Qt chain | 39 ok |
| Qt's chain, stores p and p2, frozen 0.78.0 | the same five digests; SDK base's, Flameshot's and Notes' layers are the published ones; the SDK's and runtime's TOCs match the published ones but for order |
| zigsaw 0.77 and the new Qt runtime, through a local zot | full and lazy pulls, and Designer opens |
| 0.78, the same, lazily | 37 files hydrated ahead, nothing fetched on demand for Designer |
| `scripts/package.sh`, then `defender-scan.sh` | 0.78.0's six programs clean |
| `tests/self.sh` against the package | 0 failed |

Time from the start of the pull to first use, from ghcr.io, all in the same hour (some 5 to
10 MB/s). The Qt rows are the published images, before the re-pin and lists:

| | full pull | 0.77 `--lazy` | 0.78 `--lazy` | fetched on demand |
|---|---|---|---|---|
| llvm-mingw, `clang hello.c` | 23.7 s | 23.3 s | 15.7 s | 139 MB |
| Qt's runtime, Designer's window | 12.5 s | 15.7 s | 12.8 s | 71 MB |
| Qt's SDK, `moc --version` | 46.8 s | 50.8 s | 35.8 s | 1.2 MB |
| VSCodium's window | 38.0 s | 61.1 s | 27.7 s | 369 MB |
| TeX Live, a first `pdflatex` | 96.6 s | 86.3 s | 62.5 s | 17.7 MB |

TeX Live's first `pdflatex` still takes some 23 s for its 135 files, one after another. A list, as
Qt's images now have, would take that away, but its recipe can only have one if it's published again.

The swap probe was on llvm-mingw's 5,381 files. Hydrating what was left and reverting the
placeholders gave the same bytes and attributes, with no streams, and only times differed. But:

| | first `clang` | later ones | libLLVM's image section |
|---|---|---|---|
| reverted placeholders | 0.32 s | 0.33 s | 66 ms |
| a fresh copy | 0.52 s | 0.24 s | 0.45 ms |
| a fresh copy, its files read first | 0.49 s | 0.24 s | |

0.78.0's programs here, to compare with the release's:

| Program | SHA-256 |
|---|---|
| `zigsaw.exe` | `cb238989faaaa6bc9db2bf7d33b5e1b6c9db6f2d5fbc8971d35521609a7a402e` |
| `zigsaw-shim.exe` | `8fbb05244838487d2b961dc8e7fc092cbfe64d0e53397cb5d3efa00b6605fc4e` |
| `zigsaw-shimw.exe` | `fd5f2a34ace0fc4b6b957479a321c4964ce7e0f8a517899bca59a442027d63b4` |
| `zigsaw-relay.exe` | `412fed0fe6e4675448891c0f45787ed5aaa529c11c52020a3b9d9518247f42b4` |
| `zigsaw-host.exe` | `ce52a5db1c031cfee7a178465c3522b07e4b5bdf6f313b7e96c06fa58b1060fe` |
| `zigsaw-notify.exe` | `6145accd029eada6f6b6dc90ef31316320217c5306f3b12cff3f3cf65bb549ee` |

## What went wrong

- **77's two red rows were my test's**: they compared what a run printed on stderr, which differs
  where breakaway is refused. Such a job wasn't tried here before CI ran. Now `jobprobe injob` can
  run the whole suite in one.
- **The first new reader made TeX Live's pull twice as slow**: its download took three connections
  while the pull was still downloading. I measured, then changed the order.
- **A pull of the new reader with no memory blocks** made each program header its own request. I
  found it from the same measurement.
- **A measurement went wrong on my quoting** (`\\$z`): ten runs that pulled nothing, run again.

## Not checked

- **Designer's and `moc`'s first use with lists, from ghcr.io**: the new Qt images aren't published
  yet. Through a local zot, Designer fetched nothing on demand.
- **`update --lazy` of a real image**, an extension pulled with `--lazy`, and a reboot with
  placeholders. 77's gaps still stand.
- **Why TeX Live's first `pdflatex` after the swap takes 15 to 22 s**, slower than after a full pull
  (10 s). The probe answered for llvm-mingw, not for TeX Live.
- **A real upgrade from v0.76.0 to v0.77.0** waits on `SHA256SUMS.sig`.

## On this machine

Scratch is in `D:\zs\i78`:
- `p` and `p2`, the Qt chain's stores; keep `p` until it's published;
- `bin`, frozen 0.78.0, and `bin77`, the v0.77.0 release;
- `real`, the measurement kit (`run.sh`; `ZBIN` and `MODES` pick the zigsaw and the pulls);
- `rec`, the recorded lists;
- `swap`, the probe and its llvm-mingw store;
- `lab.sh`, the local-zot check;
- `suites.sh`, `pkg`, `logs`, `lt`.

No scheduled task was made, and the kits' `ZigsawTest` keys are gone.

## Next

Each after the one before; yours unless it says otherwise.

1. **Commit and push stargazer 0.4.0** in `stargazer/`, first, as zigsaw's commit points at it.
2. **Publish Qt's chain before pushing zigsaw**:
   `COSIGN='E:\zs\i74\oci\deploy\c8a2493280a2737a6feba18c684b1744950dfc928244e17555862f77651d7ca3\cosign.exe' COSIGN_KEY='<the signing key>\cosign.key' ZIGSAW_HOME='D:/zs/i78/p' ZIGSAW='D:\zs\i78\bin\zigsaw.exe' scripts/publish.sh qt6-sdk-base.json qt6-sdk.json qt6.json flameshot.json notes.json`
3. **Commit and push zigsaw**, with `git add --chmod=+x scripts/record-prefetch.sh` and the new
   `scripts/record-prefetch.sh` and this file. I'll read Reproduce: the `lazy.sh` step and the
   qt-base, qt and qt-suites groups first.
4. **`sign-release.sh v0.77.0`**, still owed. I then try a real upgrade from v0.76.0.
5. **Tag v0.78.0.** I'll read Release and its scan, and compare with the table above.
6. **`sign-release.sh v0.78.0`.** I then try a real upgrade from v0.77.0, and measure Designer and
   Qt's SDK with their lists from ghcr.io.

Also: the weekly Upstream and Reproduce runs on 2026-11-09, which I read next session. Later: a list
for TeX Live, and for llvm-mingw and VSCodium, the next time they're published (TeX Live's is
recorded, in `D:\zs\i78\rec\texlive.txt`).
