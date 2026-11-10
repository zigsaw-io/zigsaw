# Iteration 85: One kind of volume

Started 2026-11-10, from "I don't like the current discrepancy of volume & data". Since 0.80 an
app's state was two things with two sets of rules: its data directory (`data\<id>`, deleted by `rm
--delete-data` and `prune --data`, no commands of its own) and volumes (`volumes\<name>`, `zigsaw
volume ...`, `volume prune`). This iteration makes them one: an app's data directory is its own
volume. zigsaw is **0.85.0**. No image changes, so nothing is to be published.

It started with what 84 left: Reproduce 42782909429 on `624edca` was green.

## Outcome

- **An app's data is its own volume**, named by its id, in `volumes\<id>`. `zigsaw volume ls` lists
  it with the named ones, `volume inspect <id>` shows it, `volume rm <id>` deletes it once the app is
  uninstalled.
- **One rule for what's left over**: a volume in the store that nothing mounts. An installed app
  mounts its own; a saved `--volume` mounts the one it names. `zigsaw volume prune` and `zigsaw prune
  --volumes` delete the rest, uninstalled apps' data with the unmounted named volumes. `zigsaw prune`
  names them. `prune --data` is refused, and says to use `--volumes`.
- **`--volume=<source>:.`** mounts a named volume or a folder of yours as all of an app's data, in
  the place of its own volume: `zigsaw override --volume=D:\pg:. org.postgresql.PostgreSQL`. It follows
  the rules of any mount: a saved one moves the app's files into an empty volume on the same drive,
  one only on a command line refuses over existing data, `--novolume=.` takes it away and leaves
  the files.
- **Stores from before 0.85 move over by themselves**: the first command moves each app's
  `data\<id>` to `volumes\<id>` and says so, `zigsaw repair` points commands and shortcuts there.
- **`rm --delete-data` keeps its name and meaning**: the app's own volume goes, the ones it mounted
  stay.
- **`tests/volumes.sh`**: 97 checks (63 before), 18 s.

## Decisions

Yours (2026-11-10):

- **Two concepts were what bothered you**, rather than the commands, the cleanup flags or the wording
  alone.
- **Data moves to `volumes\<id>`**, over my recommendation to leave it in `data\<id>` and unify only
  the model. What that costs is under [What it breaks](#what-it-breaks).
- **`--volume=<source>:.`** for a whole data directory elsewhere.
- **One prune rule**, with `prune --data` refused rather than quietly widened.

Mine, say if you disagree:

- **A mount at `.` is a junction at `volumes\<id>`**, rather than the run using the folder's own
  path. Every path the app sees stays `<store>\volumes\<id>\...` whatever is mounted, so shims,
  shortcuts and the HKCU records keyed by the data path don't change when a mount does.
- **The folder mounted there is granted as a host path**, labelled low or given to the AppContainer,
  recorded and taken back as any mount's is, and not labelled as the app's own volume is. A soft run
  leaves its label alone for the same reason.
- **One app per folder at `.`**: two apps' settings, registry hives and temporary files can't share
  one. A second app's run refuses, as does a `--global` mount there. Other apps may still mount the
  same volume at a path of theirs.
- **Not read-only, and not for `--ephemeral`**: an app's data can't be read-only, and a fresh data
  directory is what an ephemeral run is for.
- **The root's link is made first and taken away last**: the other mounts' links are inside its
  folder. When the root mount goes, so do they; the next run makes those that stand again.
- **`volume rm` refuses the data of an installed app**, and points at `rm --delete-data`.
- **Names and ids share `volumes\`.** A named volume's name has no dot and published ids all have
  one. For an id without a dot: the app owns the volume of that name, no other app may mount it,
  `volume create` won't take the name, and the app's run refuses if a saved mount names that volume
  already.
- **An app's own volume is in use while its runs' lock is held** (`grants\<id>.txt.lock`), so no
  new lock file.
- **Migration is per app, under the runs' lock**, never while a run of the app goes on (an older
  zigsaw's too). Every command tries, quietly; only a run of that app fails and says why. What a
  run that didn't end left in HKCU goes back into the data first, as its record names the old path.
- **If both `data\<id>` and `volumes\<id>` have files**, as after an older zigsaw ran the app again,
  `volumes\<id>` is used and each run says the other is there. zigsaw doesn't merge or delete it.
- **`volume create --path` wasn't extended to apps' ids**: `--volume=<folder>:.` does that.

## What it breaks

- **Paths an app saved in its own files** as `...\data\<id>\...` lead nowhere after the move.
- **A zigsaw before 0.85 on a moved store** finds no data, makes `data\` again and starts each app
  empty. 0.85 then tells you, and uses `volumes\<id>`.
- **Overrides with a mount at `.`** are refused by 0.80 to 0.84, which don't know the target.
- **Scripts with `prune --data`** fail until they say `--volumes`, which deletes more.
- **Shortcuts** keep the old working directory until `zigsaw repair`, which installing and `zigsaw
  upgrade` run.

## Results

| Suite | Checks | Time |
|---|---|---|
| unit | pass | |
| `volumes.sh` | 97 | 18 s |
| `sandbox.sh` | 142 | 54 s |
| `store.sh` | 17 | 22 s |
| `shims.sh` | 55 | 49 s |
| `postgresql.sh` | 61 | 92 s |
| `reach.sh` | 32 of 33 | 27 s |

`reach.sh`'s one failure is this machine's: "rm takes it all out of the real registry" wants
`HKCU\Software\Zigsaw` gone, and it holds `Grants` records that kit stores of iterations 71 to 84
left.

A real store moved: `D:\zs\i79\p` (0.79's, four apps). VSCodium's, Meld's and TeX Live's data moved
to `volumes\`. PostgreSQL's didn't, because the suite makes `volumes\<id>` itself before its first
run; the old folder held no files.

## What went wrong

- **A mount under a mount at `.` failed with `NotDir`**: `junction.link` made the parent directory
  with `createDirPath`, which refuses a path that is itself a link. It now only makes a parent that
  isn't there. The suite found it.
- **My migration test moved the data before it looked**: every command migrates, the test's own
  `hold` included.
- **I made a branch, then went back to `main`**, where earlier iterations were left uncommitted for
  you.

## Not checked

- **`self.sh`, the matrix, and the suites that only had paths rewritten** (build, certs, chromium,
  files, gtk, gtk3, guiapps, java, oci, osm2pgsql, php, qt, texlive, zls): 55 lines changed by one
  `sed`. CI runs most of them.
- **A real upgrade from v0.83.0 on a store with shortcuts and `${data}` commands**, and `repair`
  after it.
- **A mount at `.` across drives** (it refuses and says to move the files by hand), on a Dev Drive,
  for an app with registry keys, for a GUI app, and for a lazily pulled one.
- **Migration with a leftover HKCU record** from a run that didn't end.
- **AppContainer on windows-2025** with a mount at `.`: checked here on Windows 11 only.
- **The package and a Defender scan.**

## On this machine

- Kit `D:\zs\i85`: `suites.sh <suite>...`, logs in `logs\`.
- `D:\zs\i79\p` is now a 0.85 store; `data\org.postgresql.PostgreSQL` is left in it, with folders
  and no files, so runs of PostgreSQL there say so.
- `HKCU\Software\Zigsaw\Grants` has records of deleted kit stores. `zigsaw repair` would take them
  back; I left them.

## Next

Each after the one before; yours unless it says otherwise.

1. **Commit and push.** I'll read Reproduce: every suite with a rewritten path runs there.
2. **Tag v0.85.0.** I'll read Release.
3. **A real upgrade** from v0.83.0 or v0.81.0, mine, with a store that has data, shortcuts and an
   npm global command: the move, `repair`, and the app's first run.
