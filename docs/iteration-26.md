# Iteration 26: projects that carry their own recipe

Concluded 2026-10-16.

## Outcome

- **`zigsaw build` in a project's directory** builds the `zigsaw.json` at
  its root, as `make` builds a Makefile and `makepkg` a PKGBUILD;
  `zigsaw build <dir>` builds the one in `<dir>`. zigsaw 0.26.0.
- **A project's own files as a source**: a `path` that names a directory
  gives the files git would commit in it, read from the project's
  `.gitignore` files by zigsaw itself, less what `skip` leaves out. They're
  hashed as the build takes them, so an unchanged project reuses its image,
  and the image records what it was built from.
- **zigsaw builds itself**: this repository's [`zigsaw.json`](../zigsaw.json)
  builds zigsaw from the checkout in zig's image, and its programs are the
  same bytes as a `zig build -Dstrip` outside zigsaw, as releases are
  built. The Release workflow checks it on each release's package.

## Starting decisions

From the planning session (in the conversation, no plan file):

- **The files git would commit** (your pick over everything but `.git`,
  and over git's tracked files only): zigsaw matches `.gitignore` patterns
  itself, so git needn't be installed.
- **zigsaw's own repository as the proof** (your pick over adding ZLS, a
  Zig project with dependencies, and over fixtures only).
- **The version written in the manifest** (your pick over computing it, as
  PKGBUILD's `pkgver()` does).
- Mine: the name `zigsaw.json`, in the recipe format; a `path` naming a
  directory rather than a new kind of source; the current directory only,
  as make and makepkg look; a project's files kept out of the download
  cache, as local files are; the self-build checked in the Release
  workflow, so CI's time per push doesn't grow.

## What was built

### Manifests in projects

- [`src/main.zig`](../src/main.zig): `build` takes a recipe, a directory,
  or nothing; [`builder.recipePath`](../src/builder.zig) finds the
  directory's `zigsaw.json`, and says so when there's none.
- [`src/recipe.zig`](../src/recipe.zig): a source's `skip`, with
  `cleanup`'s patterns, for a directory `path` only; a `path` needs no file
  name, as it may be a directory.

### The files git would commit

- [`src/gitignore.zig`](../src/gitignore.zig): `.gitignore` files parsed
  as git does (comments, `!`, trailing spaces and their escape, a BOM,
  CRLF), and matched as git's wildmatch does with `WM_PATHNAME` and
  `WM_CASEFOLD` (`*`, `?`, classes with ranges and POSIX names, `**` as a
  whole component); the nearest `.gitignore` decides, its last match
  winning.
- [`src/project.zig`](../src/project.zig): a walk of the directory that
  doesn't enter what's ignored, leaves out `.git` and empty directories,
  starts again with a nested repository's own `.gitignore` files, reads
  those above the directory up to its repository's top, and refuses links.
  `Snapshots` takes each directory source's files once per build, with
  their hash, and checks them again after the build copied them.
- [`src/Tree.zig`](../src/Tree.zig): `contentHash`, the sha256 of a tree as
  an uncompressed layer, as a vendor step's files are hashed; `addTree`.
- [`src/builder.zig`](../src/builder.zig): the hash in the build's inputs
  and in `build.sources`; the files copied to `B:\src\<module>`, or
  streamed into the layer for a module without build commands; vendor
  steps get them too.

### zigsaw's own

- [`zigsaw.json`](../zigsaw.json): `zig build -Dstrip -p %PREFIX%` in cmd,
  with zig's image, skipping what isn't an input to the programs; it exports
  nothing, as `zigsaw` is a name only zigsaw's own program has.
- [`tests/self.sh`](../tests/self.sh), and a step in the
  [Release workflow](../.github/workflows/release.yml), on its package.

### Tests

- Unit tests: wildmatch, parsing, the rules of nested `.gitignore` files; a
  project's files (ignored, re-included, anchored, nested repository,
  skipped, empty directories, a subdirectory with the rules above it), the
  hash, and the check after copying; `skip`'s validation.
- [`tests/build.sh`](../tests/build.sh), "projects with a zigsaw.json":
  a scratch git repository whose build lists what it got, compared with
  `git ls-files -co --exclude-standard`.

## Results

### Tests

- Unit tests: 103 (99 + 4).
- `tests/build.sh`, the projects section alone: 13 of 13, 16 s, and the C
  fixture, whose sources are files, built and ran as before. CI's `build`
  job runs all of it.
- `tests/self.sh`: 6 of 6, against a `zig build -Dstrip` of the checkout
  (the build 157 s in a fresh store); 6 of 6 against the package
  `scripts/package.sh` made, whose own zigsaw built the checkout (153 s).
- Not run again: the sandbox, shims, store, registry, matrix, PHP and GTK
  suites, as nothing they cover changed.

### Timings

| zigsaw building its own zigsaw.json | |
|---|---|
| fresh store | 157 s, and 30 s to pull zig's image |
| with zig's `${cache}` warm | 67 s |
| nothing changed | under a second (the image built before) |
| taking its 52 files | 10 to 35 ms |

No published image changed, so there's nothing to republish.

## Decisions made along the way

- **`"shell": "cmd"` in zigsaw's `zigsaw.json`**, so that zig's image is
  its only SDK, without BusyBox.
- **Its `skip` leaves out what isn't an input to the programs** (`docs`,
  `recipes`, `scripts`, `tests`, `.github`, `README.md`), so that editing
  them doesn't build it again.
- **The files are checked after the build copied them**, rather than
  copied into the store first and built from there, which would cost a copy
  on every `zigsaw build`, even one that takes the image built before.
- **A directory a `.gitignore` above it ignores fails**, as git would
  commit none of it, and so does one with no files to commit.
- **In the Release workflow, the package's own zigsaw builds the
  checkout**, as the job has no other (`scripts/package.sh` builds in a
  directory of its own); its time limit went from 20 to 30 minutes.
- **`-v` names each directory source's files**: how many, from where, and
  their hash, as the image records it.

## After the push

The Reproduce run of this iteration's commit failed, as iteration 25's
had, at "org.kanboard.Kanboard: runs" in `tests/published.sh`: the check
ran each published app with `--version`, which Kanboard's launcher refuses
with its usage. Kanboard's command is a web server, so the check now starts
it with `--no-browser` on a port of its own, and wants its login page
(2 s); the image is as published. In the same run, `tests/zot.sh` failed
after all of `tests/registry.sh`'s checks passed, as removing the zot
registries' working directory found it still in use, for a moment, by zot
exiting; it now tries again for up to ten seconds. That step also exited
with 3840, which nothing in the scripts returns; to watch on the next run.

## Known gaps

See [gaps.md](gaps.md): a project builds from scratch each time it
changes; each build reads all of a project's files; a file git tracks
although ignored, and links; `push --sources` and a project's files.

## For you

- Commit and push; then I check both CI jobs and their times.
- Tag v0.26.0 for the release, whose workflow now runs `tests/self.sh`;
  then I check it.

## Suggested for iteration 27

- A Zig project with dependencies (ZLS, say) from its own `zigsaw.json`,
  its packages fetched in a vendor step (`zig build --fetch`, then
  `--system`).
- Keeping a project's tools' incremental state between its builds.
- Extension points elsewhere: GTK's runtime (GdkPixbuf loaders, GIO
  modules, dictionaries), .NET.
