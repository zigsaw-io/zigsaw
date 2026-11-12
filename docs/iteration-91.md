# Iteration 91: A volume as a file, and back

Started 2026-11-12, from "plan to implement volume export & import". Until now a volume's files
could leave the store only by copying `volumes\<name>` by hand, with its junctions, its registry
hive and a possibly running app to get wrong; [gaps.md](gaps.md) said of the copy a rollback keeps
that it is "no backup". Now `zigsaw volume export` writes a volume to a tar, and `zigsaw volume
import` makes a tar's files a volume's. zigsaw is **0.91.0**. No image changes, so there's nothing
to publish. How it's used is in [the README](../README.md#volumes), how it works in
[how-it-works.md](how-it-works.md).

State at the start: 90 had landed (`7183448`, Reproduce 43112131223 and Release 43122305369 green;
0.89.0 is the latest release, and a tag `v0.90.0` sits on the same commit with no release).

## Outcome

- **`zigsaw volume export [--all] <name> <file>`** writes a volume's files to a tar: a named
  volume, in the store or kept elsewhere, or an app's data by the app's id. A name ending in
  `.tar.gz` or `.tgz` makes it gzip; `-` is stdout. It refuses a file that's there, writes
  `<file>.partial` and renames it when whole, and says how much it wrote and what it left out.
- **`zigsaw volume import [--replace] <name> <file>`** makes a tar's files a volume's, plain or
  gzip (told by its first bytes), `-` for stdin. The volume is made if there is none; for an app's
  id that is the app's data, installed yet or not.
- **A volume that has files is left alone unless `--replace`.** Then the archive is unpacked in a
  folder inside the volume first, and only when all of it is there are the old files renamed
  aside, the new ones renamed up, and the old ones deleted. An archive cut short, one that isn't
  a tar, or one with a name Windows can't have leaves the volume exactly as it was, and says so.
- **An app's own volume is exported without its temporary files and cache**; `--all` has them.
  The keys it keeps in HKCU are in the archive: what a killed run left there is put back in its
  data first, as before a rollback's copy.
- **Neither command works while a run uses the volume**, and both say so.
- **The archive is one other tools read**: `tar`, Windows' `tar.exe`, 7-Zip, `podman volume
  import`. And import reads theirs: GNU tar's and bsdtar's archives of a folder import as the
  same files.
- **Real PostgreSQL 18.6 from ghcr.io**: export refused while the server ran; exported (39.9 MiB,
  978 files), a row added, `import --replace`, and the row was gone; the same archive imported
  into a store that never had the app, on another drive, then the app pulled: the server came up
  with the rows.

## Decisions

Yours, by the question dialog:

- **Import over files refuses; `--replace` swaps**, over merging as podman does and refusing
  always.
- **Temporary files and cache left out of an app's data, `--all` includes them**, over leaving
  them out always and exporting everything.
- **A file only**, over a registry as a second destination.

Mine:

- **A plain tar of the folder's contents, with pax headers where the old header falls short.**
  Zig's `std.tar`, which writes layers, stops at paths of 255 bytes and files of 8 GiB, and its
  reader drops times. `src/archive.zig` has its own writer and reader: `path` for a long or
  non-ASCII name, `size` from 8 GiB (and in base 256 in the old header, as GNU tar reads it),
  `mtime` for the fraction of a second NTFS keeps. Entries are sorted, so the same folder makes
  the same tar bytes (but for the export time in the global header).
- **A global pax header says what the archive is of**: `ZIGSAW.volume`, `ZIGSAW.app` and
  `ZIGSAW.version` for an app's data, `ZIGSAW.zigsaw`, `ZIGSAW.exported`. Other tools pass over
  it; import prints it. Nothing is refused by it.
- **Unpack inside the volume's own folder**, `.zigsaw-import-<random>\`, then rename what's in
  it up. That is the volume's drive whether it's in the store or kept elsewhere, the new files
  inherit the folder's low label and an AppContainer's access as they're made, and the folder
  itself is never renamed, so its grants, its record and a junction to it stay.
- **Removing the import folder is what says the renames are done.** A leftover import folder
  alone is an unpack that stopped: the next import deletes it, an export leaves it out. A
  leftover `.zigsaw-replaced-…` alone is a delete that stopped: deleted too. Both at once is a
  death between renames: export and import refuse and name the two folders.
- **Every name in an archive is checked before anything is made**: relative, no `..`, no drive
  or stream (`:`), no part that is a device's name, ends in a dot or blank, or has a character
  Windows refuses. Links and devices in a foreign archive are passed over and counted. Files
  are created exclusive, so two names that differ only by case fail rather than merge.
- **Export holds the app's runs lock, or the volume's, exclusively**, as `volume rm` does: a
  run that starts meanwhile waits or fails, and none goes on.
- **gzip only**, with the compressor layers use. Zig's std reads zstd but doesn't write it.

Deviation from the plan: it said junctions of saved mounts among the old files stay in place
through a `--replace`. They go with the old files instead (the link, never what it leads to), all
of them alike, at the top of the data or deeper, and the app's next run makes its mounts again.
In exchange, an archive that has files where one of the app's saved mounts goes is refused before
anything is renamed: it would otherwise fail the app's next run, or hide under the mount.

## What changed

| File | What |
|---|---|
| `src/archive.zig` (new) | the tar `Writer` and `Reader` with pax, `pack` (a folder's walk), `unpack`, `nameProblem`, tests |
| `src/volumes.zig` | `exportTo`, `importFrom`, `swapIn`, `settleImports`, `failIfMountedAtRoot`, `failIfUnderMount`; `isValidPart` public |
| `src/main.zig` | `volume export`, `volume import`, usage |
| `src/snapshot.zig` | `left_out`, `long`, `absolute` public |
| `src/Context.zig` | `stdin`, as `stdout` |
| `src/win32.zig` | `SetFileAttributesW`, `FILE_ATTRIBUTE_READONLY`, `ERROR_SHARING_VIOLATION` |
| `tests/volumes.sh` | 35 new rows, 135 in all |
| `README.md`, `docs/how-it-works.md`, `docs/gaps.md`, `docs/findings.md` | the commands, how the swap is ordered, what stays open, what a file costs to make |
| `build.zig.zon`, `zigsaw.json` | 0.91.0 |

## Tests

`tests/volumes.sh`, new rows (all in a temporary store, busybox apps):

- export to a tar that Git Bash's `tar` and `C:\Windows\System32\tar.exe` list, a 120-character
  file name and a folder with no files among it; refusals (file there, file in the volume, no
  such volume), and no `.partial` left;
- import into a new volume: same tree (`diff -r`), the same time on a file to 100 ns, the
  read-only file read-only; `.tar.gz`; `export - | import -` through a Git Bash pipe; archives
  made by GNU tar and by Windows' tar;
- over files: refused without `--replace`; with it, the old files gone, the volume's low label,
  its grant record and an AppContainer's ACE still on the folder and inherited by the new files,
  which a low run and an AppContainer's read and write;
- a run uses the volume: both refuse;
- an archive cut short (plain and gzip), a file that isn't a tar, 4 KiB of zeros: nothing changes,
  no volume is made, nothing is left behind;
- `../escaped.txt`, `C:/escaped.txt` and `sub/nul.txt` in an archive (GNU tar's `--transform`):
  refused, and nothing written outside;
- leftovers: left out of an export, deleted by the next import, and the half state refused by
  both;
- an app's data: `cache\` and the temporary folder left out, `--all` has them, `ZIGSAW.app` in
  the header, a mounted volume's junction passed over and said; an archive with files at a
  saved mount's target refused; `--replace` takes the data back to the archive's and the next
  run has its mount again;
- registry: a run killed with its key in HKCU, export, and the key is out of HKCU and in the
  archive's hive; `rm --delete-data`, import by the id with the app not installed, build, and a
  run reads the value;
- data mounted from a folder of yours: refused by the app's id, both ways; an empty volume's
  archive imports as an empty volume.

Unit tests in `src/archive.zig`: a folder packed and unpacked (a path of more than 255 bytes, a
non-ASCII name, empty folders, a time with a fraction, read-only, a junction passed over, what's
left out, the same bytes twice); a 9 GiB size through pax and base 256; what other tars write
(`./`, GNU `L` names, links, old-style folders); archives cut short and not tars; names.

Results on this machine, final build:

| Suite | Result |
|---|---|
| `zig build test` | pass |
| `tests/volumes.sh` | 135 ok (35 new), 32 s; one skip, as before (`SECOND_DRIVE` isn't set here) |
| `tests/rollback.sh` | 55 ok |
| `tests/store.sh` | 17 ok |
| `tests/sandbox.sh` | 142 ok, with its temporary folder on D: (see "Not checked") |
| `tests/upgrade.sh` | 30 ok, v0.80.0 and v0.83.0 to this checkout's package |
| the package | `zigsaw.exe` `faee816e`, 0.91.0; Defender finds nothing in its six programs |

## What it costs

Measured here, one run each unless a range is given; D: is NTFS, E: a Dev Drive (ReFS).

| | export `.tar` | export `.tar.gz` | import `.tar` | import `.tar.gz` | `import --replace` |
|---|---|---|---|---|---|
| 20,000 files of 4 KiB, D: | 1.6 to 1.8 s | 4.8 s | 19 to 23 s | 24 s | 22 to 24 s |
| 20,000 files of 4 KiB, E: | 1.5 s | | 19 to 20 s | | 22 s |
| 1 GB in 10 files, D: | 1.4 s | 22 s | 0.9 s | 5.6 s | 1.0 s |
| 1 GB in 10 files, E: | 2.0 s | 22 s | 1.0 s | 5.5 s | 0.9 s |
| PostgreSQL's data, 39.9 MiB in 978 files, D: | 0.1 s (4.3 s the first time) | | 0.6 s (to E:) | | 0.85 s |

- **Many small files import slowly, and it isn't zigsaw's doing.** Windows' `tar.exe` unpacks the
  same 20,000 files in 4 to 8 s, Git Bash's `tar` in 8. A program of 40 lines that only creates
  them takes 19 s, as zigsaw does, with one thread or eight, through Zig's `Io` or plain Win32
  ([findings](findings.md#what-a-file-costs-to-make-iteration-91)). The plan said to write small
  files from several threads if the import was much slower than a rollback's copy; I built that,
  it measured 19.8 s against 20.3, and I took it out.
- **gzip is 45 MB/s** on data half random and half zeros (1 GB to 501 MiB); reading it back is
  180 MB/s. A plain tar goes as fast as the drive.
- **A file's exact time costs 1 KiB in the tar**: 78 MiB of 4 KiB files make an archive of
  107 MiB, where `tar.exe`'s, with whole seconds, is 88 MiB.
- **The first export after an app wrote its files can be slow**: 4.3 s for PostgreSQL's 978 files
  right after its server stopped, then 0.1 s each time. One sample.

## What I got wrong on the way

- **A file of zeros is a valid tar with nothing in it.** `import --replace` would have deleted
  a volume's files for it. Found reading my own code after the suite was green; now an archive
  with no entries imports only if it has zigsaw's header (an export of an empty volume).
- **Export read past a half-finished import**, leaving both leftover folders out and writing an
  archive of whatever was at the top. It refuses now, as import does.
- **An archive could bring a folder named `.zigsaw-import-…`**, which the next import would
  have deleted as a leftover. Such names at the archive's top are refused.
- **The export's message had no archive size**: the file was asked for its size through a handle
  opened only to write. It's asked by name after the rename.
- **My first cost figures were of 20,000 copies of one file**, and said an import takes 7 s.
  With files that differ it takes 19 to 23 s. The table above is of files that differ.
- **I took the slow import for my code's**, and tried four ways of writing the files and a rename
  that tolerates open files before timing the phases, which showed the writes, and then a bare
  program, which showed it's the machine. The parallel writer and the switches are out again.
- **One import took 460 s** in the middle of those runs, between two of 19 s, with nothing
  changed. I couldn't make it happen again, and don't know what it was.

## Not checked

- **Another machine.** Every import here was into a store of the same user on the same machine,
  on another drive at most. An archive's registry hive (`registry\user.dat`) loaded under
  another user account, and data with paths of the old store in it, weren't tried.
- **Files over 8 GiB, and paths over 260 characters in a real volume.** The unit tests write a
  9 GiB size into a header and read it back, and pack a path of over 255 bytes; no file that
  large was exported.
- **A kill between the renames of `--replace`.** The half state is made by hand in the suite
  (both leftover folders) and refused; no run was killed there.
- **`podman volume import` and 7-Zip making archives.** 7-Zip and both tars read zigsaw's
  archive, and both tars' archives import; podman wasn't run.
- **stdout to a console** is refused by code that no test reaches (the suite has no console).
- **An export that a `pull` waits for**, and a run that starts during an export.
- **Whether Defender is what makes small files slow.** Nothing here could turn it off; the
  bare program says it's the machine and not zigsaw, not which part of the machine.
- **CI.** The new rows run on a runner for the first time when you push: its `tar.exe`, its Git
  Bash's `tar --transform`, `stat` and `attrib`.
- `tests/sandbox.sh` has four rows that fail with the suite's temporary folder on E:, where
  `icacls /setintegritylevel` is refused ("Access is denied"); with it on D: all 142 pass. That
  is the drive, and was so before this iteration. The matrix, `self.sh` and the GUI suites
  weren't run: nothing they cover changed.

## Yours to do

- Commit and push. I read the Reproduce run, `tests/volumes.sh` first: its new rows run on the
  runner for the first time, with its `tar.exe` and its Git Bash.
- The tag `v0.91.0` is yours; I read the Release run after it.
