# Iteration 80: Volumes

Started 2026-11-08. An app's state was its data directory, and all of it went together: `rm
--delete-data`, `prune --data` and the end of an `--ephemeral` run deleted everything in it, and no
other app could share any of it. Putting PostgreSQL's cluster on another drive took both
`--env=PGDATA=…` and `--filesystem=…`, and an app whose path no variable sets couldn't be moved at all.
This iteration adds volumes, as Docker has them, where they fit Windows. zigsaw is **0.80.0**. No image
changes, so nothing is to be published.

It started with what 79 left:
- **CI.** Reproduce 42306597412 and Release v0.79.0 (42309523337) were green. v0.79.0 has
  `SHA256SUMS.sig`.
- **A real upgrade** from the real v0.78.0 (`D:\zs\i80\upg.sh`): `zigsaw upgrade` gave all six
  programs of v0.79.0's zip byte for byte, and a second upgrade said it was up to date. GitHub answered
  5xx twice before that, which the retries got past.
- **TeX Live from ghcr.io**, and a lazy pull over the published version before it: see
  [Results](#results).

## Outcome

- **`--volume=<source>:<path>[:ro]`** on `run` and `override`, and **`--novolume=<path>`**. It mounts
  a source at a path in the app's data directory:
  - **a named volume**: a folder in the store, `volumes\<name>\`, made by the first run that mounts
    it;
  - **a named volume kept elsewhere**: `zigsaw volume create --path=<dir> <name>` records a folder
    of yours;
  - **a folder of yours**, by its absolute path: a bind mount.
- **A mount is a directory junction** at that path. Windows has no mount namespace, so this is the
  only place a volume can appear. Deleting the data directory stops at the junction, so volumes
  outlive `rm --delete-data`, `prune --data` and `--ephemeral`, with no code of their own for that.
- **The folder is granted as a `--filesystem` path is**: labelled low, or given to the app's
  AppContainer, recorded, in the ledger, and taken back by the same rules. A mount on the command
  line goes with the app's last run; a saved one stays until `--novolume`. That is also what takes a
  shared volume's AppContainer access back once an app stops mounting it.
- **A saved mount over the app's own files moves them into an empty volume**, as Docker fills an
  empty volume. PostgreSQL's cluster moves into one with `zigsaw override --volume=pgdata:data
  org.postgresql.PostgreSQL`.
- **`zigsaw volume create/ls/inspect/rm/prune`.** `rm` deletes a volume in the store and only forgets
  one kept elsewhere; it refuses one an override mounts or a run uses. `prune` deletes only volumes in
  the store that no override mounts. `zigsaw prune` counts those, and `rm --delete-data` says which
  volumes it kept.
- **`tests/volumes.sh`**, 63 checks in 9 s, in CI beside `tests/sandbox.sh`; and a volume row in
  `tests/postgresql.sh` (11 checks).

## Decisions

Yours:

- **Named volumes in the store, bind mounts, and named volumes kept elsewhere.** Not volumes declared
  by images (a recipe field like Dockerfile's `VOLUME`), which would have meant republishing.
- **Move the app's files into an empty volume** when a mount goes over them, rather than refusing or
  copying.

Mine, say if you disagree:

- **The target is relative to the data directory**; a leading `${data}\` is allowed. It can't be,
  hold or be in what zigsaw keeps there: `registry`, `home`, its `AppData` folders, the temporary
  folder, an AppContainer's `Packages`, Quick access, and the links to your folders. Two mounts can't
  overlap: a junction inside another mount's folder would be inside the volume.
- **Every source resolves to a folder that goes through the host-grant code**, rather than volumes
  having a lifetime of their own. `grants.Own.refusal` exempts `<store>\volumes\<name>` and what's in
  it, and nothing else of the store; the files beside the folders have a dot, which a name can't.
- **Names: 2 to 64 letters, digits, `_` and `-`**, case-insensitive. No dots, so `<name>.json` and
  `<name>.lock` can't be a volume. Not a device's name, nor `cwd` or a folder's name, which
  `--filesystem` uses. `d:data` is then the volume `d`, which is refused, never a drive.
- **Only a saved, writable mount moves files**, and only when no other run of the app goes on. A
  mount on the command line over the app's files would hide them after the run, so it refuses. The
  move only renames, so it works only on the drive of the app's data; across drives it refuses and
  says to move them by hand. Moved files keep what they inherited where they were, so the volume's
  ACL and label are then written again (`acl.reinherit`).
- **A run makes its mounts before it joins the app's runs** (as `unlabelData` does), where it can
  tell whether another goes on. Only then may it replace a link that points elsewhere.
- **`grants\<id>.mounts` lists the links zigsaw made**, written before any is made, as grants are, so
  that a run that fails part-way leaves none that stays. `grants.settle` removes those no saved mount
  names, under any sandbox. `rm` removes them all.
- **A bind mount must exist, and can't hold the store or the data directory**: a junction to it
  would make a loop. Docker's `-v` makes a missing folder; zigsaw's `--file` and this don't.
- **No `-v`**: that's `--verbose`.
- **Overrides with volumes need 0.80**: an older zigsaw refuses the file, as for every new setting
  (`override --reset` gets it working). Without volumes the file is as before.
- **Not in the plan: `tests/postgresql.sh`'s gzip dump row** left `postgres-gz` behind, so a second
  run in the same store failed. It now clears it first, and at the end.

## Results

**From ghcr.io**, the published TeX Live `7d55caed`, from the start of the pull to its first
`pdflatex`, with the real releases:

| | pull | first `pdflatex` | total |
|---|---|---|---|
| full, 0.79 | 80.5 s | 9.7 s | 90.2 s |
| `--lazy`, 0.78 | 23.9 s | 14.0 s | 37.9 s |
| `--lazy`, 0.79 | 22.2 s | 12.7 s | 34.9 s |

Nothing was fetched on demand: the list hydrated 234 files ahead of use.

**The published TeX Live `99b0c1d4`, then the published `7d55caed` lazily over it** (a pull of the
tag: the first, pulled by digest, is pinned, so `update` leaves it):

| What | Result |
|---|---|
| TeX Live's layer | 241.0 MB copied from the store in 172 ms; 9.1 MB from ghcr.io (3.9 by the download, 5.3 for reads) |
| Perl's layer | 52.2 MB downloaded, as the old one was gzip |
| Pull, then first `pdflatex` | 34.7 s, then 13.1 s: 48.0 s in all |

The pull over an install took 12.5 s more than a fresh lazy pull, as 79 saw through a local zot.

**The published VSCodium `fcc9d40f` from ghcr.io**, from the start of the pull to its window, one
run each:

| | pull | window | total | fetched on demand |
|---|---|---|---|---|
| full, 0.79 | 40.8 s | 1.1 s | 41.9 s | |
| `--lazy`, 0.78 | 6.4 s | 9.3 s | 15.7 s | 5 files, 324.9 MB; 190 hydrated ahead |
| `--lazy`, 0.79 | 8.4 s | 11.8 s | 20.2 s | 44 files, 336.1 MB; 150 hydrated ahead |

The window reads most of the layer, so a lazy pull wins by not unpacking first. 0.79's helper no
longer unpacks beside a run (79's fix for TeX Live), which would explain its 44 fetches against 0.78's
5: files the download had were fetched again rather than unpacked. Whether that costs VSCodium 4.5 s
needs more than one run each over the network; TeX Live gained from the same change.

**The package** (`D:\zs\i80\pkg`, `scripts/package.sh`), which Defender scanned clean
(`scripts/defender-scan.sh`):

| Program | sha256 |
|---|---|
| `zigsaw.exe` | `8551a09867a478344991be6253db8527ed212424ca32c1877186969d00d76ea5` |
| `zigsaw-shim.exe` | `94701941bfaf34d6a514f36f4bc5cc409ca69d6e48241065d3c0a52bfc29f1c8` |
| `zigsaw-shimw.exe` | `49c1dce5bad59578f068e102c6b7e16f17b513ac0985f0d57932184a6aacf07c` |
| `zigsaw-relay.exe` | `4e43aabd4412f61db4ae30aaca3328d5fab6f78d4953b9356c1ad8c56dd6bc68` |
| `zigsaw-host.exe` | `858cfce0340f7b8bad743e6f7442ea0b6b346d36a87282f2aa061584417677a6` |
| `zigsaw-notify.exe` | `a2ec62c828aeff3d64ff7fc16cbb21ceff0bc46dcd50d1c9e02ed08705024682` |

**Suites** (`D:\zs\i80\logs\suites\summary.txt`, then volumes and PostgreSQL again after the last
fix):

| Suite | Checks | Time |
|---|---|---|
| unit | 195 of 195 | |
| `volumes.sh` | 63 | 9 s |
| `sandbox.sh` | 142 | 48 s |
| `store.sh` | 17 | 22 s |
| `shims.sh` | 55 | 47 s |
| `postgresql.sh` | 61 (11 new) | 73 s |
| `self.sh` | 20 | 11 min |

## What went wrong

- **My first `volumes.sh` left a run going.** Its `hold` started a low run that wrote a marker in a
  folder it wasn't granted, so the marker never came, and nothing released the run. It held the
  volume, and kept the AppContainer row from settling. It now grants that folder, and releases even
  when the start fails; I ended the run by giving it its stop file.
- **The first draft recorded the links after making them.** A run whose second mount failed would
  have left the first link unrecorded, for good. A check for it failed on that build, and passes now.
- **`update --lazy` from ghcr.io measured nothing at first**: the old TeX Live pulled by digest is
  pinned to it.

## Not checked

- **Whether 0.79's VSCodium is slower lazily than 0.78's**, and whether waiting for no run to unpack
  is what does it: see [Results](#results).
- **The matrix**: its store, `D:\zs\i55\p`, is gone, and rebuilding its toolchains takes long. Runs
  with no volume do what they did before: `volumes.prepare` returns at once.
- **A volume on a Dev Drive, or on ReFS**, and a bind mount across drives: junctions work there, but
  no suite ran it.
- **Windows Server 2025 and older Windows 11** under `--sandbox=appcontainer`: a volume is a junction
  into the store, where a container sees nothing above the data directory. CI runs volumes.sh on
  windows-2025.
- **Two apps writing one volume at once**: nothing stops it, as nothing does in Docker.

## On this machine

Scratch is in `D:\zs\i80`:
- `upg.sh` (the real upgrade), `ghcr.sh` (the ghcr.io times), `suites.sh`, `logs`, `rel` (the
  v0.78.0 and v0.79.0 zips, unpacked), `pkg` (the package).
- The PostgreSQL suite ran in `D:\zs\i79\p`, which it leaves as it found it.
- No store is kept: the suites' are temporary. No scheduled task was made, and the kits' `ZigsawTest`
  keys are gone.

## Next

Each after the one before; yours unless it says otherwise.

1. **Commit and push.** I'll read Reproduce: `tests/volumes.sh` runs on CI for the first time.
2. **Tag v0.80.0.** I'll read Release and its scan.
3. **`sign-release.sh v0.80.0`.** I'll then upgrade from v0.79.0 for real.

Also: the weekly Upstream and Reproduce runs on 2026-11-09.
