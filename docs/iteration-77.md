# Iteration 77: Lazy pulling

Started 2026-11-06. [The Cloud Files experiment](experiment-cloud-files.md) of 2026-11-04 showed that
an eStargz layer can run from placeholders that Windows fills as they're read, with no admin and in
every sandbox, and recommended a bridge: start from placeholders while the layer downloads, then become
an ordinary deployment. This iteration builds that as `zigsaw pull --lazy`. zigsaw is **0.77.0**, and
stargazer **0.3.0**. TeX Live moves to eStargz, so there's one image to publish. How it's used is in
[the README](../README.md#pulling-lazily), how it works in [how-it-works.md](how-it-works.md#lazy-pulls),
what it doesn't do in [gaps.md](gaps.md), and what was found in
[findings.md](findings.md#lazy-pulling-built-iteration-77).

It started with what 76 left: Reproduce and Release had gone green, `SHA256SUMS.sig` was there,
v0.76.0's six programs were the bytes of 76's table, and real upgrades from v0.75.0 and v0.74.0 to
v0.76.0 went through, a changed `SHA256SUMS` refused.

## Outcome

- **`zigsaw pull --lazy` and `update --lazy`** install an app before its eStargz layers of 32 MiB or
  more are downloaded. Each such layer's deployment is placeholders, made from its TOC, which is checked
  against the signed manifest. A helper, zigsaw itself, gives Windows each file's bytes the first time
  something reads it, each chunk checked against the TOC, while it downloads the whole blob. Once the
  blob is in and checked, and no run uses the layer, it swaps in the unpacked files and ends. From then
  on the app is as if pulled whole.
- **Under soft, low and AppContainer**, an app starts from placeholders, and nothing it starts can leave
  its job.
- **The helper comes back**: any run of the app, or a build using the image, starts it again if it's
  gone, and it goes on with the download from where the last one got to. `rm` and `prune` stop it.
- **A run that fails says which files couldn't be fetched, and why**, where the app itself would only
  say `BAD_EXE_FORMAT`. `list` says how far the download is. `push` refuses an app that's still
  downloading.
- **A volume that can't have placeholders** (a Dev Drive, as `E:` here; a share; FAT) gets the layer
  downloaded whole, with a note.
- **GitHub's Windows Server 2025 has Cloud Files**: a probe on a branch of its own ran BusyBox from
  placeholders under all three sandboxes there, before anything was built on it.
- **What it saves on today's images is little**, and sometimes it costs: llvm-mingw's `clang` 2.5 s
  sooner; VSCodium 9 s later, as its 239 MB program has to be all there; Qt's SDK nothing, as its
  runtimes are gzip layers that download first. See [Results](#results).
- **TeX Live is on eStargz**: the same digest in two stores, `99b0c1d407f1`. Of its 236 MB, a first
  `pdflatex` reads 17.7.

## Decisions

Yours:

- **Lazy pulling** as the theme, over a report of what sources bring along, a toolchain round,
  refusing unsigned images, and rollbacks that restore data.
- **`--lazy` is opt-in**; the default is unchanged.
- **The five eStargz images, and TeX Live moved to eStargz**.
- **A probe branch first**, so that Server 2025's answer came before anything was built on it.

Mine, say if you disagree:

- **The bridge, as the experiment recommended**: placeholders last until the layer is downloaded.
- **The helper is a hidden subcommand**, `zigsaw lazy-helper`, run from a copy in the store's `lazy`
  folder. That's no 7th program for Defender to judge, and no install, upgrade or packaging list to
  change, and zigsaw.exe can be replaced while it runs. One per layer, as Windows allows one provider
  per root.
- **The helper makes the placeholders**, the case the experiment proved, and `pull` waits until it's
  ready.
- **The shim's job allows breakaway, the app's never does.** Where another job refuses, the helper
  stays in it and zigsaw says so.
- **A helper that's gone is started again** by the next run, rather than the run swapping itself.
- **The swap renames first**: an interrupted swap leaves no deployment, which the next deploy unpacks
  from the complete blob, rather than half a folder that looks whole.
- **A run makes sure of its helper before it locks its deployments**, so a helper that's done can swap
  in between.
- **Installing reads program headers from the index**, so that a shim's kind doesn't fetch a whole
  program.
- **`update --lazy` takes no delta**: it downloads the new layer whole in the background.
- **No progress reports to Windows within a chunk**: a chunk that takes over 60 s fails, and the read is
  tried again (gaps.md).
- **The README says plainly when it doesn't help**, as measured.

## Results

| What | Result |
|---|---|
| `tests/lazy.sh`, new, under `tests/zot.sh` | 23 ok, about 20 s, with a row on this machine's real Dev Drive |
| Unit tests (cloudfiles, lazy, pe's header from bytes; stargazer's chunk reads) | 165 + stargazer 25 and its C smoke test |
| `registry`, `store`, `rollback`, `updates`, `signing` | 113, 17, 32, 42, 34 ok |
| `sandbox`, `shims`, `install`, `build` base group | 142, 55, 45, 92 ok |
| `tests/self.sh` against the package | 19 ok |
| `scripts/package.sh`, then `defender-scan.sh` | 0.77.0's six programs clean |
| Probe run 42151690186 on `probe/cfapi` (Server 2025 Datacenter 10.0.26100.33674) | cldflt loaded; three sandboxes on C: and D:; 362 and 193 with no provider; a read by URL from ghcr.io |
| TeX Live on eStargz, stores p and p2, frozen v0.76.0 | `99b0c1d407f1cbab71a77605517cea028e2387564f0a01f12a1c6222e66cf6f8` in both, 515 and 454 s |
| llvm-mingw from ghcr.io by hand | `clang` from placeholders; download, digest, swap to plain files; warm run 245 ms |

Time from the start of the pull to first use, this machine, some 10 MB/s from ghcr.io:

| | full pull | `--lazy` | fetched on demand | swap after |
|---|---|---|---|---|
| llvm-mingw, `clang hello.c` | 21.9 s | 19.4 s | 139 MB | 34 s |
| Qt's runtime, Designer's window | 11.6 s | 16.7 s | 71 MB | 38 s |
| VSCodium's window | 37.4 s | 46.6 s | 369 MB (`VSCodium.exe` 239) | 66 s |
| Qt's SDK, `moc --version` | 51.1 s | 52.0 s | (128 MB of gzip runtimes first) | |
| TeX Live, a first `pdflatex`, from a local zot | 69.1 s | 64.8 s | 17.7 MB | 78 s |

After the swap, the first run is cold again: TeX Live's `pdflatex` 13.8 s, then 0.3 s. Windows showed
no notification during VSCodium's lazy run, which you watched.

0.77.0's programs here, to compare with the release's:

| Program | SHA-256 |
|---|---|
| `zigsaw.exe` | `05cabf079e31ed1a4dc7e8b26f0442d89589d5c779109d8344abd6218f7ea4b7` |
| `zigsaw-shim.exe` | `def9854fa939b54ffed02b08f61e73164a4f4f2cb95a1a4d76bff9c883ecd2cd` |
| `zigsaw-shimw.exe` | `c9a20a8e306acd29032578698afefbe537bdff98fc7cc19bb23ab166cbe20a9f` |
| `zigsaw-relay.exe` | `900b5f632b378e0173947cc370b511c759c9bc2426cf76867684e1473e3fc356` |
| `zigsaw-host.exe` | `24c04e41a69b936cc912350b0f7f707581f084648c58fe851dee314a69411617` |
| `zigsaw-notify.exe` | `1f627b8cfc082ccf0add8e8de59dac3af2d118124c2fc2a39cf99eef35257374` |

## What went wrong

- **What it saves is far from the experiment's 1.7 to 8 times.** That timed one layer alone; real images
  bring gzip runtimes, Electron's program is most of its layer, and a first run's files come one after
  another. The README and findings say so, with the numbers.
- **The probe workflow I handed over didn't parse**: a step name with `C: ` in it. I now check workflows
  with a YAML parser before handing them over.
- **The probe's standard-user row failed on my mistake**: the provider's own process started a program
  from its placeholders, which Windows refuses (error 395). Fixed on the branch; not run again yet.
- **`prune` skipped placeholders**: a sync root lists as a reparse point, not a directory, so a lazy
  deployment no app used would never have gone. Found while cleaning up by hand; fixed, with a row.
- **I deleted a scratch store's folder before `zigsaw rm`**, against my own rule, which left its
  placeholders, their helper and a running Notes. Stopped by hand, then `prune` (once fixed) removed
  them. Nothing outside `D:\zs\i77` was touched.
- **The suite's first runs failed on the test, not the code**: `taskkill //F` reaches Windows as
  written under `MSYS_NO_PATHCONV`, `tasklist` matches pid 0, and the helper wrote its pid a second late.
  The helper now writes its state before it's ready.
- **Two measurements hung**: Notes showed no window in a scratch store, and Designer's New Form dialog
  kept its window from closing. Designer stands in for Notes, and the kit ends a run that doesn't close.

## Not checked

- **The probe's standard-user rows**, which wait on your push of the fix.
- **TeX Live lazily from ghcr.io**, the likeliest win: it can only be measured once it's published.
- **A reboot** with placeholders and no helper: the next helper registers the folder again if Windows
  forgot it, which is untested.
- **`update --lazy` of a real image**, and an extension pulled with `--lazy` (gaps.md).
- **Other antivirus**, and Explorer drawing a lazy app's shortcut icon, which fetches its program.

## On this machine

Scratch is in `D:\zs\i77` (NTFS: `E:` is a Dev Drive): stores `p` and `p2` with TeX Live, `real` and
`exp` from the measurements (apps removed), `upg`, `smoke`, `lt`, `pkg`, and the probe worktree
`D:\zs\i77\probe` on branch `probe/cfapi`. No scheduled task was made, and the kits' `ZigsawTest` keys
are gone.

## Next

Each after the one before; yours unless it says otherwise.

1. **Push the probe fix**: `cd /d/zs/i77/probe && git commit -m "Probe: start BusyBox through cmd" && git
   push`. I'll read its standard-user rows.
2. **Commit and push stargazer 0.3.0** in `stargazer/`.
3. **Publish TeX Live before pushing zigsaw**:
   `COSIGN='E:\zs\i74\oci\deploy\c8a2493280a2737a6feba18c684b1744950dfc928244e17555862f77651d7ca3\cosign.exe' COSIGN_KEY='<the signing key>\cosign.key' ZIGSAW_HOME='D:/zs/i77/p' ZIGSAW='D:\zs\i77\bin\zigsaw.exe' scripts/publish.sh texlive.json`
4. **Commit and push zigsaw**, with `git add --chmod=+x tests/lazy.sh` and the new `src/cloudfiles.zig`,
   `src/lazy.zig`, `src/LazyHelper.zig`, `src/BlobReader.zig`, `tests/lazy.sh`, `tests/jobprobe.zig`,
   `docs/experiment-cloud-files.md` and this file. reproduce.yml changed, so it's a long run; I'll read
   Reproduce, the `lazy.sh` step first.
5. **Tag v0.77.0.** I'll read Release and its scan, and compare with the table above.
6. **`sign-release.sh v0.77.0`.** I then try a real upgrade from v0.76.0, and measure TeX Live lazily
   from ghcr.io.

Also: the weekly Upstream and Reproduce runs on 2026-11-09, which I read next session. Later, if lazy
pulling is to pay: runtimes and pins on eStargz, and fetching in parallel what a first run will read
(eStargz's prioritized files, or a recorded list).
