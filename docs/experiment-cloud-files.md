# Experiment: lazy running with the Cloud Files API

Run 2026-11-04 on the `experiment/cfapi` branch. No zigsaw code changed: the
provider is a test program, `tests/cfprobe.zig` on that branch, which
makes a folder where a deployment belongs, so that an unmodified `zigsaw run`
uses it as it would any other.

[Iteration 77](iteration-77.md) built the bridge this recommends, as
`zigsaw pull --lazy` ([src/lazy.zig](../src/lazy.zig)), after the same probe
passed on GitHub's Windows Server 2025.

The question: can an app run from an eStargz layer that hasn't been
downloaded, with Windows asking for each file as something first opens it,
without admin rights and under zigsaw's sandboxes? [Layer
formats](layer-formats.md) left this open: "the Cloud Files API is untested
with AppContainer and low IL".

The images were llvm-mingw (110 MB blob, 5,381 files, 404 MB) and Qt's SDK
(own layer 96 MB, 10,195 files, 318 MB), both already on eStargz. The machine
runs Windows 11 Home 10.0.26300 with Defender's real-time protection on and no
exclusions, on an NVMe SSD (Ryzen 7 5700U, 15 GB), on a link that downloads
from ghcr.io's storage at about 15 MB/s. The lazy runs over the network read the
blob from ghcr.io's storage by Range requests, with the local copy moved away.

## Outcome

- **It works, without admin, in every sandbox.** A non-elevated process can
  register a folder, connect, and make placeholders. Under low integrity and
  under AppContainer, a process that reads, maps or loads a dehydrated file, or
  starts a dehydrated program, gets it. zigsaw's deny entry and its grants on
  the deployment don't get in the way.
- **It fits zigsaw's store unchanged.** `zigsaw run`, `rm` and `prune` worked on
  such a folder with no change. Roots under `%LOCALAPPDATA%` work, and each cost
  about 38 ms to register, process start included. `CfRegisterSyncRoot` adds
  nothing to the registry keys that list sync roots or Explorer's navigation
  pane.
- **Time to first use falls 1.7 to 8 times, by how little of the image is used:**

  | from nothing | full pull | lazily | blob read |
  |---|---|---|---|
  | Qt SDK's own layer, `moc --version` | ~24 s (that layer only) | 3.0 s | 8 of 92 MB, with `rcc` and `qmake` |
  | llvm-mingw, `clang --version` | 17 s | 6.4 s | 51 of 105 MB |
  | llvm-mingw, `clang hello.c` | 17 s | 7.5 s | 64 of 105 MB |
  | llvm-mingw, `clang++` with `<iostream>` | 18 s | 10.9 s | 70 of 105 MB |
  | the same, replaying a recorded file list | 18 s | 7.6 s | 70 of 105 MB |

  Lazily means blocks of 1 MiB. llvm-mingw is close to the worst case: two DLLs
  are 45% of its blob, and almost every command loads them.
- **Fetching per file loses to a full pull.** With one request per file, that
  `clang++` took 27 s (though it ran first, on the coldest CDN). A scattered 4 KiB
  range from the registry's storage took 0.65 to 1.3 s when it missed the CDN's
  cache, about as long as 16 MiB (1.06 s). Blocks of 1 MiB make 70 requests of
  those 464.
- **Warm runs cost more for big images.** Creating an image section for a
  hydrated 77 MB DLL takes 60 ms every time, against 0.5 ms for a plain copy
  of the same bytes. `clang --version` goes from 67 to ~155 ms, unless the file
  is replaced. Small programs aren't affected. We didn't find the cause; see
  [The image section](#the-image-section).
- **First opens are deferred, not avoided.** Each file's first open costs ~7.5 ms
  more, one after another, which is 34 to 51 s to read all of llvm-mingw for the
  first time, against 0.4 s after an unpack. It looks like Defender scanning a
  file it hasn't seen, which an unpack pays for when writing, but we couldn't
  prove that without admin. Hydrating itself is cheap: from a local blob, 8 threads
  hydrated all 5,381 files in 1.4 to 1.9 s, against 5.8 s to unpack.
- **One root has one provider**, and it has to stay. A second connection is
  refused (`ERROR_CLOUD_FILE_ALREADY_CONNECTED`). Once the provider is gone,
  dehydrated files fail, and a program or DLL fails with **`BAD_EXE_FORMAT`**
  (193), which says nothing of the cause.
- **NTFS only, here.** A Dev Drive refuses it: error 478, "the file system
  minifilter cannot attach to the developer volume". Microsoft documents a way for
  an admin to allow filters on a Dev Drive; we didn't try that, or ReFS outside a
  Dev Drive.

**Recommendation: lazy running is worth building as a bridge, not as a way of
keeping apps.** The first run starts from placeholders while the blob downloads
in the background; when the download is complete and checked, the next run
unpacks it as today, and the root goes away. That keeps warm runs exactly as fast
as they are, needs a provider only while a root is in use, and leaves "a blob in
the store is complete and checked against its digest" true once the bridge is
over. See [What a bridge would need](#what-a-bridge-would-need). It reverses a
decision of 2026-10-31 ("lazy running is out of scope for now") and a principle
of [Layer formats](layer-formats.md) ("no filesystem driver", though no driver is
installed here: `cldflt` comes with Windows), which is for the project to decide.

## Method

`zigsaw-cfprobe mount <root> <blob or URL> -- <command>` opens the blob's TOC
through stargazer, registers the folder with `CfRegisterSyncRoot` (Progressive
hydration, population `ALWAYS_FULL`, so that no directory ever needs a callback),
makes a placeholder of each directory and file with `CfCreatePlaceholders`,
directory by directory, and runs the command. On `FETCH_DATA` it reads and inflates
the chunks that cover the range, checks each against its digest from the TOC, and
hands them over with `CfExecute`. It logs each fetch and the process that caused
it. cldapi.dll is loaded at run time, as zig has no import library for it.

The folder is the layer's `deploy\<hex>\`. `Store.deploy` finds it there and
doesn't unpack, then protects it as usual, so what ran is zigsaw's real path.
`--block-kib` reads whole blocks into a cache. A URL reads ranges through WinHTTP,
from the storage ghcr.io redirects to. `--net-ms` slows a local blob down, for the
failure tests.

Times come from `bench.exe`, the VHDX experiment's tool (see the `experiment/vhdx`
branch), so that no shell's startup is in them: `exec` starts a program and waits
for it, and reports the first run and the median. "From nothing" adds the TOC and
the placeholders to the first run.

## Measurements

### Deploying

| llvm-mingw | unpack | placeholders |
|---|---|---|
| making the tree | 5.8 s | 0.55 s |
| protecting it | 0.44 s | not timed |
| reading the TOC, by Range | | 0.3 to 1.6 s |
| walking it | 14 ms | 18 ms |
| `stat` of every entry, with its DOS path | 313 ms | ~375 ms, with nothing fetched |
| reading every file, warm | 334 ms | 465 ms |
| reading every file, first time | 361 ms | 34 to 51 s |

Qt SDK's layer: 13.4 s to unpack and 1.2 s to protect, against 1.35 s for 11,001
placeholders.

A plain open fetches the whole file, as the lazy-sshfs project found of the same
API: a 300 KB file's open took 12 ms and its first read 0.5 ms. So what's lazy is
the file, not the page, which suits eStargz and rules out reading part of a large
DLL. `stat`, walking and `GetFileAttributes` fetch nothing, and
`GetFinalPathNameByHandleW` gives a DOS path, under AppContainer too: the realpath
failures of the VHDX experiment don't arise.

### From nothing, real network

One command each, on a fresh root. These times are the command's alone:

| blocks | `clang --version` | requests | blob read |
|---|---|---|---|
| none | 5.7 s | 37 | 47.7 MB |
| 256 KiB | 7.6 s | 195 | 48.8 MB |
| 1 MiB | 5.6 s | 51 | 51.0 MB |
| 4 MiB | 4.9 s | 14 | 56.0 MB |
| 16 MiB | 4.5 s | 4 | 64.0 MB |

| blocks | `clang hello.c` | requests | blob read |
|---|---|---|---|
| none | 6.9 s | 62 | 50.5 MB |
| 1 MiB | 6.6 s | 64 | 64.0 MB |
| 4 MiB | 8.5 s | 22 | 88.0 MB |

| blocks | `clang++` with `<iostream>` (434 files) | requests | blob read |
|---|---|---|---|
| none | 24.7 s | 464 | 51.9 MB |
| 1 MiB | 10.0 s | 70 | 70.0 MB |
| 4 MiB | 9.9 s | 22 | 88.0 MB |
| 1 MiB, list replayed on 8 threads first | 5.4 s + 1.4 s | 70 | 70.0 MB |
| 1 MiB, `--sandbox=low` | 10.9 s | 70 | 70.0 MB |

Add the TOC (0.3 to 1.6 s) and the placeholders (0.55 s) to each. A real deployment
runs that `clang++` in 0.56 s the first time. Full pulls, measured last, after these
runs: 17 s for llvm-mingw (8 s to download, 7 s to unpack) and 41 s for Qt's SDK;
measured first, 20 and 44 s. Each row is one run, on a CDN that was warming as we
went: treat differences of a second or so as noise.

Qt's SDK, its own layer lazily and its other layers as usual, from nothing: TOC
0.37 s, 11,001 placeholders 1.35 s, `moc --version` 1.24 s, then `rcc` 1.04 s and
`qmake` 0.21 s. The three read 8 MB of the blob's 92, in 8 requests.

### Warm

The median of three, with every file they use hydrated. Through `zigsaw run`, but
for busybox, which is started directly:

| | real deployment | hydrated | |
|---|---|---|---|
| `clang --version` | 67 ms | 151 to 164 ms | loads libLLVM and libclang-cpp |
| `clang -c hello.c` | 87 ms | 174 to 188 ms | |
| `clang hello.c` | 173 ms | 256 ms | |
| `clang++` with `<iostream>` | 496 ms | 654 to 676 ms | |
| `moc --version` (Qt) | 43 ms | 45 ms | small images |
| busybox (719 KB, no DLLs) | 14 ms | 15 ms | no difference |

### The image section

The cost goes with the size of the DLLs a process loads, and is one step of
loading them. For `libLLVM-23.dll`, 77 MB:

| | open | `CreateFileMapping(SEC_IMAGE)` | map |
|---|---|---|---|
| a plain copy | 0.10 ms | 0.5 ms | 0.06 ms |
| as hydrated | 0.09 ms | **60 ms** | 0.07 ms |
| as hydrated, another process holding it mapped | 0.07 ms | 0.7 ms | 0.05 ms |

So Windows seems to throw away the image section of such a file when its last user
closes it, and rebuild it for the next. What we ruled out or found:

| the file | section | so |
|---|---|---|
| placeholder, provider connected | 60 ms | |
| placeholder, no provider | 60 ms | not the callbacks |
| reverted to a plain file (`CfRevertPlaceholder`) and unregistered | 60 ms | not the reparse point or the root |
| that, with one byte rewritten in place and its time set | 60 ms | not a missing write |
| after a non-buffered open | 60 ms | no change, though we can't say it dropped what's in memory |
| **a plain copy renamed over it, inside the root** | **0.5 ms** | **431 ms, once** |

The hydrated file isn't sparse, and has fewer extents than a copy (19 against 40).
It loads at the same address with the same private memory, so the process isn't
relocating it. The children's own CPU time triples (user ~25 ms against ~9, kernel
~45 against ~13). Defender's CPU, by its performance counter, didn't settle
anything. Whether the state is on disk or in memory, and so whether a reboot cures
it, is **not known**.

### When things go wrong

| what | what the reader sees |
|---|---|
| no provider, reading | open succeeds, `ReadFile` fails: 362, `PROVIDER_NOT_RUNNING` |
| no provider, mapping | 362 |
| no provider, `LoadLibrary`, `CreateProcess` | **193, `BAD_EXE_FORMAT`** |
| the provider killed under a waiting reader | at once: 404, `PROVIDER_TERMINATED`; no hang; a new provider then serves the file |
| a chunk failing its digest | 383, `VALIDATION_FAILED`; the file stays dehydrated; Windows asks twice |
| a chunk that won't inflate | 389, `UNSUCCESSFUL`; the same |
| a stall of 70 s | Windows cancels at 60 s (`IO_TIMEOUT`); the read asks again, blocks, and succeeds when the data arrives |
| a second provider | connecting fails: 378, `ALREADY_CONNECTED` |
| the provider's run ends while another uses the layer | the other gets 362 on what isn't hydrated yet |

Two more that shape a design:

- **A provider's own process is different.** With
  `CF_CONNECT_FLAG_BLOCK_SELF_IMPLICIT_HYDRATION`, which lazy-sshfs found it needs,
  it can't start a dehydrated program (395, `ACCESS_DENIED`), though
  `CfHydratePlaceholder` first works. Zig's directory walker finds no files in the
  tree there, it seems as placeholders show as reparse points to that process. And
  only that process may call `CfRevertPlaceholder` (another gets 395).
- **Unregistering deletes dehydrated files and keeps hydrated ones.** `zigsaw rm`
  deleted a protected, partly hydrated root with no provider, and Windows had nothing
  to unregister afterwards.

### Sandboxes

On a fresh root each time, with zigsaw's deny entry on it and, under AppContainer,
the app's capability granted on it:

| a confined process... | soft | low | appcontainer |
|---|---|---|---|
| starts a dehydrated program | ok | ok | ok |
| `ReadFile` on a dehydrated file | ok | ok | ok |
| `MapViewOfFile` on one | ok | ok | ok |
| `LoadLibrary` of one | ok | ok | ok |
| lists `D:\_foss\zigsaw\docs\gaps.md` | not run | ok | **denied**, as it should be |

The provider's log names the confined process as the one fetching each. That last
row shows the AppContainer was one, and the low run's token said
`Mandatory Label\Low`. `clang++` itself fails under AppContainer with
`clang-23: Permission denied`, on a real deployment too, so that's the toolchain's
gap and not this; its image asks for soft.

## What a bridge would need

Not built. From the above:

1. **Starting**: for a layer the store lacks, with an index, `Store.deploy` makes a
   root at `deploy\<hex>\` from the TOC, already checked against the manifest, so that
   the path an app sees never changes. Any other layer deploys as today. So does
   everything on a volume that refuses it, such as a Dev Drive: the failure comes at
   once, from `CfRegisterSyncRoot`.
2. **A process of its own**: one provider per root, which must outlive the run that
   started it if another joins, and which sees the tree differently, all point to a
   small detached helper per store, gone when no run holds such a deployment's lock.
   That also keeps `zigsaw run` itself ordinary.
3. **Reading**: through blocks of 1 MiB, the chunks checked against the TOC as here,
   by `RemoteBlob`, which has credentials and redirects. Report progress on slow
   fetches, to stay inside Windows' 60 s.
4. **The download**: the whole blob, in the background, by the code that pulls now,
   and checked against its digest at the end.
5. **Ending**: with the blob in and no run holding the deployment's lock, the next run
   unpacks it as today, deletes the root, and renames the new tree into place.
6. **Saying why**: a failed fetch should reach the user in words, as apps will only
   ever say `BAD_EXE_FORMAT` or similar. The helper can log it where `zigsaw run` will
   look when an app exits with an error.

And later, if a list proves worth keeping: eStargz's prioritized files are for just
this. A list recorded earlier, hydrated and opened on several threads before the run
starts, cut that `clang++` from 10.9 to 7.6 s, by taking the first opens in parallel.

The alternatives, and why not:

- **Keeping roots for good**, for images used little: saves disk, but keeps the
  provider, the failure modes and the warm cost for big images, and each run needs the
  registry reachable for files it hasn't used yet. Replacing big images with plain
  copies would fix the warm cost alone.
- **Holding sections open in the helper** avoids the 60 ms too, but only while it runs.

## Not tested

- **Windows Server 2025**, so CI: whether `cldflt` is there and allows this. Nothing
  here says it does, and CI would need it.
- **Reboots**: whether a registration survives one (lazy-sshfs found it survives a
  crash), and whether the image section's cost does.
- **Toasts**: Windows can tell the user when an app downloads files from a sync
  provider. None was looked for during these runs; somebody should watch for one.
- **GUI apps** on a lazy runtime, and whether one provider process can hold several
  roots, as a multi-layer image would want.
- **Hydration policies** other than Progressive.
- **Real network failures**: a failed Range request takes the same path as the failed
  chunks above, but none was provoked.
- **Other antivirus**, and Defender with exclusions: we can't change those without
  admin. Other machines' first-open costs may differ a lot.
