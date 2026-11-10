# Iteration 86: The way up

Started 2026-11-11, from "plan iteration 86", with **upgrade path + 0.85 cleanup** your pick over
required signatures, an upstream round and an Electron runtime. zigsaw is **0.86.0**. No published
image changes, so nothing is to be published.

It started with what 85 left: Reproduce 42841026887 on `9f18f3c` was red on one row, in
`tests/matrix.sh`.

## Outcome

- **Main is green again, as far as I can see from here**: the red row, "git global config in
  data dir", looked for `data` in the path git names, which is `volumes\<id>` since 85. 85's
  `sed` rewrote `data\\` paths only, and missed this one. It now looks for
  `volumes\org.git_scm.MinGit\`, checked against MinGit's real output.
- **`tests/upgrade.sh`, a real upgrade from real releases.** For each of v0.80.0 (the first with
  volumes) and v0.83.0 (the newest that kept data in `data\`), it downloads the release from GitHub,
  checks the zip against a hash in the script, and installs it with the release's own
  `install.ps1` into a scratch store. That zigsaw installs an app and leaves what a user's store
  has: data, a command a run added under `${data}\bin`, a shortcut, a named volume an override
  mounts, and registry keys a killed run left in HKCU. Then **it** runs `zigsaw upgrade`, to a
  package of this checkout signed by a key of the run's own, and 15 rows per release check the
  store: data moved, the keys back in the app's hive, the command, the export, the shortcut's
  folder, the named volume, the older zigsaw run again, `rm --delete-data` and `volume prune`.
  30 rows, 14 to 16 s. Reproduce runs it on every push, and the Release workflow on its package.
- **A `data\<id>` left with only empty folders goes, without a word.** An older zigsaw run on a
  moved store makes `home\` and the like; 0.85 warned about them on every run, as it did in
  85's kit with PostgreSQL. A file or a link anywhere in it keeps the whole tree, and the warning.
- **85's unchecked mounts at `.`**: an app with registry keys keeps its hive in the mounted
  folder, and HKCU has the keys only while it runs; a mount on another drive refuses to move the
  app's files and leaves them. `tests/volumes.sh` has 101 rows (97 before); the drive row runs
  where `SECOND_DRIVE` names one, as Reproduce now does (C:, with the store on D:).
- **gtk4-msvc**: libtiff 4.7.2 calls its option `tiff-cxx`, so the recipe's `-Dcxx=OFF` did
  nothing and `tiffxx.lib` was built; its archive members' dates were what made two builds differ.
  The recipe says `-Dtiff-cxx=OFF` now, and **gtk4-msvc reproduces**: two fresh stores built
  `f9a83d99` (10.5 min each), with no `tiffxx` in it. It's still local only: CI has no Visual
  Studio, and it isn't published.

## Decisions

Yours (2026-11-11):

- **This iteration's theme**: upgrade path + 0.85 cleanup.

Mine, say if you disagree:

- **v0.80.0 and v0.83.0**, rather than every release or the newest only: the first with volumes
  (data and named volumes side by side, the hardest store to move) and the newest before the move.
  `RELEASES` takes others; a release needs its hash in the script.
- **The suite downloads from GitHub**, as a user's first install does, with `RELEASES_DIR` for a
  folder of them. A release whose zip isn't the pinned bytes fails its rows.
- **BusyBox through the source mirror when nothing has it**: frippery.org still answers 403, and
  only BusyBox's own recipe falls back to the copy next to its image, so the suite builds that
  recipe once with this zigsaw when `SEED_DOWNLOADS` lacks it (the Release workflow has no seed).
- **One package for `install.sh` and `upgrade.sh` on CI**: a Package step, as the Release workflow
  has, instead of each suite packaging (80 s each).
- **The older zigsaw run again is a row, not a fix**: it starts the app empty, as 85's "What it
  breaks" says; the row keeps that true and checks that the new zigsaw says what it left.
- **gtk4-sdk-base keeps `-Dcxx=OFF`**, the same dead option: it's published and reproduces (its
  archiver writes no dates), and changing its recipe would make every GTK image's check red until
  the chain is republished. It goes with the next GTK round.
- **A lazily pulled app at a mount at `.`** isn't checked: `volumes.sh` has no registry to pull
  from, and `lazy.sh` doesn't mount. Left for when lazy pulling changes next.

## Results

| Suite | Checks | Time |
|---|---|---|
| unit | pass | |
| `upgrade.sh`, v0.80.0 and v0.83.0 to the 0.86.0 package | 30 | 16 s |
| `upgrade.sh`, v0.83.0, no seed, from GitHub | 15 | 14 s |
| `volumes.sh`, with `SECOND_DRIVE=E:` | 101 | 17 s |
| `volumes.sh`, without | 100, 1 skipped | 17 s |
| `install.sh` | 45 | 165 s |
| `store.sh` | 17 | 22 s |
| `shims.sh` | 55 | 48 s |
| `matrix.sh`'s git row, by hand against MinGit's output | matches `volumes/org.git_scm.MinGit/` | |
| gtk4-msvc, two fresh stores | same manifest `f9a83d99`, no `tiffxx` | 635 s, 623 s |
| `gtk.sh`'s six MSVC rows, by hand on that build | 6 ok | |
| `scripts/defender-scan.sh` on the 0.86.0 package | the six programs clean | |

## What went wrong

- **I ran this checkout's zigsaw on your own store.** `zigsaw grants --help`, without
  `ZIGSAW_HOME`, used `%LOCALAPPDATA%\zigsaw`, and being 0.85 it moved the data of ripgrep, Rnote
  and cosign to `volumes\` (0, 384 KB and 0 bytes; Rnote and ripgrep aren't installed). I moved
  the three back to `data\` and removed the lock file it made; `volumes\` is left, empty. cosign's
  shim names `D:\_foss\zigsaw\zig-out\bin\zigsaw.exe`, so its next run moves them again, as it
  would have anyway.
- **My kit's temporary folder was labelled low**: I'd run MinGit in it to check the matrix row,
  and a working directory's label stays. Old zigsaws installed below it then ran at low
  integrity and couldn't write `HKCU\Software\zigsaw\keys`. A fresh folder fixed it; the label on
  `D:\zs\i86\tmp` is still there (`zigsaw repair` on its store didn't take it). **I then did it
  again** with gtk4-msvc's demos in `t2`, and moved on to `t3`.
- **`grep -iF` crashes in Git Bash** on a pattern with a backslash (exit 134), which looked like a
  wrong shortcut. The suite uses `grep -F`.

## Not checked

- **The whole of `matrix.sh`** here: it builds what its store lacks, which is most of it. CI runs
  it; the one row it failed on was checked by hand.
- **The new workflow steps** (Package, `upgrade.sh` in both workflows, `SECOND_DRIVE`): they run
  first on your push and tag.
- **`updates.sh`, `self.sh` and the rest**: nothing they cover changed.
- **A lazily pulled app at a mount at `.`** (above).
- **Releases before v0.80.0** in `upgrade.sh`.

## On this machine

- Kit `D:\zs\i86`: `suites.sh <suite>...` (repackages into `pkg\` first; logs in `logs\`), `rel\`
  (the two releases), `t3\` (the temporary folder now), `g\g1` and `g\g2` (the gtk4-msvc stores,
  deletable after `zigsaw rm`), `bin\` (zigsaw 0.86.0, frozen), `probe.sh`, `gtkmsvc.sh`,
  `msvcrows.sh`.
- `D:\zs\i86\tmp` and `t2` are labelled low (above); `tmp` holds test stores from failed runs, with
  read-only files.

## What's left for you, in order

1. **Commit and push.** New: `tests/upgrade.sh` (`git add --chmod=+x tests/upgrade.sh`),
   `tests/upgrade/app.json`, `tests/volumes/registry.json`, this file. I'll read Reproduce:
   `matrix.sh`, `upgrade.sh` and `volumes.sh` first.
2. **Tag v0.86.0** (v0.85.0 needn't be tagged: 0.86 carries it). I'll read Release, whose
   `upgrade.sh` step runs on the real package.
3. **Still from 84**: `COSIGN_KEY=<the backup cosign.key> scripts/sign-release.sh --anyway v0.83.0`.
