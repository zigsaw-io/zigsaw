# Iteration 79: Lazy pulling, round 3

Started 2026-11-07. [Iteration 78](iteration-78.md) made `pull --lazy` faster than a full pull. This
iteration takes away what still held it back: big gzip runtimes that downloaded whole first, first
runs that fetched file after file, an update that downloaded what the store already had, and slow
fetches that Windows gave up on. zigsaw is **0.79.0**; stargazer is unchanged. Six images are to be
published.

It started with what 78 left, all done:
- **CI.** Reproduce 42245304005 and Release v0.78.0 were green. v0.77.0 and v0.78.0 both have
  `SHA256SUMS.sig`. The six programs in v0.78.0's zip are the bytes of 78's table. `check-pins`
  found nothing missing or unsigned.
- **Real upgrades.** These were between real, signed releases, in scratch stores
  (`D:\zs\i79\upg\run.sh`). From v0.76.0 to v0.77.0, with `ZIGSAW_UPGRADE_FROM` naming that
  release, then on to v0.78.0, and from v0.77.0 to v0.78.0: each one gave the release's own bytes.
  A second upgrade said it was up to date.
- **Designer and `moc` from ghcr.io, with their lists**: see [Results](#results).
- **A fresh upstream report** (2026-11-06): nothing urgent. The only advisories left are on CPython
  3.14.7, which Meson and Qt's SDK use at build time. frippery.org answers 403 again, and builds use
  the source mirror.

## Outcome

- **Perl and MinGit are eStargz**, so `pull --lazy` of TeX Live no longer waits for 48 MB of Perl,
  nor VSCodium for 39 MB of MinGit. MinGit is now **2.56.0.windows.4**: .3 and .4 are security
  releases. TeX Live, PostgreSQL, VSCodium and Meld are re-pinned onto them.
- **TeX Live, Perl and VSCodium have prefetch lists**, recorded from a first `pdflatex` and from
  VSCodium's first window. MinGit has none: the window doesn't run git.
- **`pull --lazy` and `update --lazy` copy what the store already has**:
  - The pull plans the new layer from the store's other eStargz layers, as a delta update does, and
    writes the copies to `plan.json`.
  - The helper copies them before it serves, and fetches only the rest.
  - An update of TeX Live took 9.1 MB of its 251 MB layer from the registry.
- **A slow fetch tells Windows how far it's got**, every 2 seconds, so that Windows' 60 seconds
  don't run out.
- **The helper unpacks only once no run uses the deployment, at background priority.** Beside a run,
  the unpack had made TeX Live's first `pdflatex` take 52 s instead of 12. This wasn't in the plan;
  see [Decisions](#decisions).
- The six images reproduce in two stores: Perl `3bd9e281`, MinGit `7560cb36`, TeX Live `7d55caed`,
  PostgreSQL `40845224`, VSCodium `fcc9d40f`, Meld `df99aab7`. PostgreSQL's and Meld's own layers
  are the published ones; only their runtime pins changed.

## Decisions

Yours:

- **Theme**: lazy pulling, round 3. You passed over the toolchain round, refusing unsigned images
  and the report's blind spots.
- **Republish six**: Perl and MinGit go to eStargz, with re-pins of TeX Live, PostgreSQL, VSCodium
  and Meld, and lists for TeX Live, Perl and VSCodium.
- **MinGit is bumped** to 2.56.0.windows.4 in the same republish.
- **llvm-mingw's list waits** for its 20261104 bump.
- **`--lazy` stays opt-in.**
- **Code**: update by ranges, and progress within a chunk.

Mine, say if you disagree:

- **Re-pinned by hand**, as in 78. `rebuild.sh perl.json` would have rebuilt the GTK SDKs, PostgreSQL's
  SDK, PostGIS and Gnumeric, which pin Perl only as an SDK.
- **The plan is made by the pull**, which has the registry and the new TOC open, and is written to
  `lazy\<hex>\plan.json`. A helper that starts again reads it.
- **A helper with a plan counts its blob in 64 KiB blocks**, so that what lies between copies
  fetches little. A 0.78 helper can't read that map, and downloads the layer again (gaps.md).
- **Copies are claimed by spans of copies, whichever blob each comes from**, not copy by copy, so
  TeX Live's reordered members don't each cost a block.
- **A wrong copy is caught by the chunk's digest when read, and by the blob's at the end**, which then
  fetches it all again without the plan.
- **Progress goes out as the file's size and what's come of the chunk**: the probe found any report
  works.
- **Perl's list is what TeX Live's first `pdflatex` reads**, not what PostgreSQL's PL/Perl does.
- **Not in the plan: the unpack waits for no run, at background priority.** It was the biggest gain
  measured, and two lines.
- **Test hooks**: `ZIGSAW_TEST_LAZY_SLOW` (bytes a second) and `ZIGSAW_TEST_LAZY_WAIT` (milliseconds
  before each request).

## Results

| What | Result |
|---|---|
| Unit tests | 189 (3 new: claimed blocks wait for their copy; a failed copy is fetched; `received` counts a fetch as it comes) |
| `tests/lazy.sh` | 34 ok in 42 s (5 new rows: update copies, a restarted helper copies nothing twice, under 3 MiB from the registry, a source gone, a wrong copy; and the slow link); 33 inside `zigsaw-jobprobe injob` |
| `LAZY_WAIT=90000 tests/lazy.sh` | BusyBox's start and `big.bin`'s fetch each waited 90 s, and nothing was cancelled |
| `rollback`, `store`, `sandbox`, `updates`, `registry`, `signing`, `shims`, `install`, `oci`, `build` base | 32, 17, 142, 42, 113, 34, 55, 45, 36, 92 ok |
| The six images, stores p and p2, frozen 0.79.0 | the same six digests |
| `tests/texlive.sh`, `tests/postgresql.sh`, `tests/chromium.sh` on store p | 20 ok (and its known gap), 50 ok, 27 ok (and its two gaps) |
| Meld's git rows of `tests/gtk3.sh` (`D:\zs\i79\meld.sh`) | git 2.56.0.windows.4 makes a repository; Meld's git support finds it, soft too |
| `scripts/package.sh`, then `defender-scan.sh` | 0.79.0's six programs clean |
| `tests/self.sh` against the package | 0 failed |

**Windows' 60 seconds**, probed with the cfprobe holding a fetch 90 s and reporting every 10:

| Report | Result |
|---|---|
| none | cancelled at 60 s, and asked for again |
| `completed` 0, the file's size as total | not cancelled |
| `completed` growing, the file's size | not cancelled |
| `completed` 0, the range's size | not cancelled |
| `completed` growing, the range's size | not cancelled |

**From ghcr.io, the published Qt images with their lists** (0.78, slice 0), from the start of the pull
to first use:

| | full pull | `--lazy` | fetched on demand |
|---|---|---|---|
| Designer's window | 28.3 s | 8.8 s | nothing (37 files hydrated ahead) |
| Qt's SDK, `moc --version` | 47.4 s | 20.9 s | nothing (457 hydrated ahead) |

**Through a local zot**, the new TeX Live, from the start of the pull to its first `pdflatex`:

| | pull | first `pdflatex` | total |
|---|---|---|---|
| full, 0.79 | 57.9 s | 10.1 s | 68.0 s |
| `--lazy`, 0.78 | 13.7 s | 52.5 s | 66.2 s |
| `--lazy`, 0.79 | 13.6 s | 12.3 s | 25.9 s |

With the download held back, so nothing unpacked beside the run, 0.79's first `pdflatex` took 11.9 s
before the fix too. So 0.78's 52 s was the unpack, not the placeholders. VSCodium's window through
the same zot: 1 s after a full pull of 11.7 s, and 9.5 s (0.78) or 8.5 s (0.79) after a lazy pull of
1.6 s. From a local registry a lazy pull saves only the unpack.

**A real `update --lazy`**, the published TeX Live `99b0c1d4` to the new `7d55caed`, through a local zot:

| What | Result |
|---|---|
| Planned | 244.4 of 251.2 MB as copies, in 0.28 s |
| Copied by the helper | 241.0 MB in 0.2 s |
| From the registry | 9.1 MB (3.9 by the download, 5.3 for reads) |
| Perl's new layer | 52 MB downloaded, as the old one was gzip |
| `update --lazy`, then the first `pdflatex` | 23.9 s, then 12.8 s; 36.9 s in all, against 79.7 before the unpack waited |

Recorded lists:

| Image | Read by | Files | MB |
|---|---|---|---|
| TeX Live | a first `pdflatex` | 135 | 17.7 |
| Perl | the same | 97 | 9.3 |
| VSCodium | its first window | 193 | 368.8 |
| MinGit | the same | 0 | |

Perl's eStargz layer is 53.6 MB against 48 MB as gzip (+12%: a gzip member per file); MinGit's is
40.0 MB.

0.79.0's programs here, to compare with the release's:

| Program | SHA-256 |
|---|---|
| `zigsaw.exe` | `eca7d2cfa18ba37666beb68cc744ad25003ff1cbfbd6f16504c34e92d9f7d785` |
| `zigsaw-shim.exe` | `73b6fc0a7540fbc0b36411cc9325f7458c272a73fb33c99d3b5db76f62460f56` |
| `zigsaw-shimw.exe` | `8129262772676d6b19145768b609899be12c3e2ec687ff06c21f149775492937` |
| `zigsaw-relay.exe` | `ed9fa0d9121d85779dc8376469a352145fc31282fa97cdada65d71973c0053a5` |
| `zigsaw-host.exe` | `e61bd7251d6b74fe7402d960282d72c3d28976e3c94614caca0350c4073c0206` |
| `zigsaw-notify.exe` | `6d31139f48619d0ce5075ae31b637604e780e7d05932bff1750d60fdd9fe23d7` |

## What went wrong

- **My first slow-link check tested the registry, not Windows.** At 40 KB/s, a local zot cut the
  request some 70 s in. Windows hadn't cancelled anything. A wait before each request
  (`ZIGSAW_TEST_LAZY_WAIT`) is what keeps a fetch past 60 s.
- **Two of the new `lazy.sh` rows failed at first, both through my mistakes in the test.** The last
  helper counts the first one's copies as "earlier", not as copies of its own. And one row's
  download wasn't held back, so nothing was left lazy to test.
- **My first lab summary broke on an empty number**, and mixed in helper logs from earlier runs. The
  update's own numbers came from a second run.

## Not checked

- **Times from ghcr.io for 79's TeX Live and VSCodium**, and a real `update --lazy` from ghcr.io:
  the images aren't published yet.
- **Whether VSCodium's list makes its window sooner.** The window reads 369 MB, most of the layer.
- **Why `update --lazy` takes some 10 s more than a fresh `pull --lazy`** of the same image.
  Planning takes 0.5 s of it.
- **Meld's windows, and the rest of `gtk3.sh`**: CI's GTK groups run them, as Meld changed.
- **An update from a version that was itself pulled lazily and not yet downloaded**: it has no whole
  blob to copy from, so it fetches (gaps.md).

## On this machine

Scratch is in `D:\zs\i79`:
- `p`, the six images to publish, and `p2`; keep `p` until it's published.
- `r`, the recording's store, and `rec`, the recorded lists.
- `bin`, frozen 0.79.0; `pkg`, the package.
- Kits: `upg` (the real upgrades), `probe` (the 60 s probe), `lab` (`lab.sh`, local zot), `why`
  (`why.sh`, the unpack's cost), `meld.sh`, `record.sh`, `chain.sh`, `rb.sh`, `suites.sh`, `logs`,
  `lt`.

The probe's `--stall-ms` and `--progress` are uncommitted edits in the `probe/cfapi` worktree,
`D:\zs\i77\probe`. No scheduled task was made, and the kits' `ZigsawTest` keys are gone.

## Next

Each after the one before; yours unless it says otherwise.

1. **Publish the six before pushing**, Perl and MinGit first (MinGit 2.56.0.windows.4 is a new tag):
   `COSIGN='E:\zs\i74\oci\deploy\c8a2493280a2737a6feba18c684b1744950dfc928244e17555862f77651d7ca3\cosign.exe' COSIGN_KEY='<the signing key>\cosign.key' ZIGSAW_HOME='D:/zs/i79/p' ZIGSAW='D:\zs\i79\bin\zigsaw.exe' scripts/publish.sh perl.json mingit.json texlive.json postgresql.json vscodium.json meld.json`
2. **Commit and push.** I'll read Reproduce. The GTK groups run, as Meld changed; `lazy.sh`, TeX
   Live, PostgreSQL and the electron group first.
3. **Tag v0.79.0.** I'll read Release and its scan, and compare with the table above.
4. **`sign-release.sh v0.79.0`.** I'll then upgrade from v0.78.0 for real, and measure from ghcr.io:
   - TeX Live and VSCodium, full against 0.78 and 0.79 lazy;
   - a real `update --lazy` of TeX Live from `99b0c1d4`.

Also: the weekly Upstream and Reproduce runs on 2026-11-09. Later:
llvm-mingw's list with its 20261104 bump, in the toolchain round.
