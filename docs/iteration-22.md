# Iteration 22: Defender, and names for recipes

Concluded 2026-10-15.

## Outcome

- **Defender's detection explained, as far as it can be from here.** What
  Defender quarantined in iteration 21 was a development build of 0.19.0,
  with debug information, flagged while it ran and then by its bytes. The
  programs of every release scan clean. A report for Microsoft is drafted
  for you to send.
- **Version information and a manifest** in `zigsaw.exe` and both shims,
  from 0.22.0: what Explorer's Properties show (version, author, licence),
  and a manifest that runs them as the user who starts them. Programs
  without either look more like malware to Defender's machine learning.
  They still build to the same bytes from any checkout.
- **Releases checked byte for byte**: a build of 0.19.0, 0.20.0 and 0.21.0
  here gives the programs of their releases, all nine.
- **`zigsaw search` and `info` against ghcr.io**, without a login: they
  work, and the README's example is what `search pdf` prints. `info` no
  longer says an image of upstream's own build was built "from its
  sources".
- **Names for Node and Go**, the two runtimes whose names cost only their
  own images and three apps' (Prettier, fzf, zot). The other ten wait for
  their next versions.
- **`zigsaw-winwait` only looks at windows of the run it's given**, so a
  browser showing an app's page can't be closed in its place.

## Starting decisions

Made in the planning session.

- Of four themes offered, **you chose Defender's false positive and
  iteration 19's leftovers**; not Flatpak's "extra data", not Files at low
  integrity and in an AppContainer.
- For Defender, beyond the diagnosis and a drafted report, **you chose
  version information and a manifest**; not code signing, not a note in
  the README.
- Names for runtimes and SDKs: **"add it for small ones, defer the big
  ones"**. A runtime's name changes its digest and so the digest of every
  image that pins it. Only Node (pinned by Prettier) and Go (fzf, zot) have
  no part in GTK's stack; busybox, zig, Rust, CMake, Meson, Perl, cargo-c
  and gettext are all pinned by GTK's SDK, which would mean rebuilding it,
  its runtime, Text Editor and Rnote.
- Mine: the version 0.22.0; the descriptions "zigsaw", "zigsaw command
  shim" and "zigsaw GUI command shim"; winwait's pid required, not
  optional.

## What was built

### Defender

- Scanned with `MpCmdRun -Scan -ScanType 3 -File <exe>
  -DisableRemediation`, which works without admin rights: the twelve
  programs of 0.18.0 to 0.21.0 are clean. Defender had flagged the
  development build (`b9b5923c…`) as it ran (`DidThreatExecute`), then two
  copies of it as they were opened.
- Restoring that file had also set the detection to "allow" on this
  machine, so local scans report it clean whatever the file
  ([findings](findings.md#other-findings)). They can't show whether 0.22.0
  fares better.
- [`src/windows/zigsaw.rc`](../src/windows/zigsaw.rc): one `VERSIONINFO`
  for the three programs; `build.zig` defines the version (from
  `build.zig.zon`), the description and the file name. It uses numbers for
  winver.h's names and `/:auto-includes none`, so no Visual Studio header
  can come into it.
- [`src/windows/zigsaw.manifest`](../src/windows/zigsaw.manifest):
  `asInvoker` and Windows 10/11 as the supported OS; no long paths, DPI
  awareness or code page, which would change how the programs behave.
- `tests/install.sh`: each installed program's version information has
  `zigsaw version`'s version and its own name, and its manifest asks for
  nothing more than the user's rights.

### Releases checked

- Each tag in a worktree of its own, `scripts/package.sh`, and the three
  programs compared with the release's zip and its notes. 0.18.0 isn't
  among them: it was built for the runner's CPU (iteration 19).

### Search and info

- `zigsaw search`, `search pdf`, `search video`, `search zzz` and `info`
  against `ghcr.io/zigsaw-io`, from a fresh store, anonymously: as
  intended.
- `info`'s "built" line said "from its sources, without an SDK" for
  SumatraPDF and Go, which are upstream's builds unpacked. An image's
  config doesn't say whether anything was compiled, so it now says "from 1
  pinned download, without an SDK" (or "…, with rust, zig and busybox").
  `info.zig`'s tests weren't among the unit tests; they are now.
- `tests/published.sh`: the catalog must describe each app whose recipe
  has a name by that name, which shows a republish that didn't push the
  catalog again.

### Names

- `recipes/node.json` ("Node.js", MIT) and `recipes/go.json` ("Go",
  BSD-3-Clause); Prettier, fzf and zot pin their new digests.

### winwait

- [`tests/winwait.zig`](../tests/winwait.zig): `zigsaw-winwait <pid> <text>
  <seconds> [--close]`. A window counts only if its process is `<pid>` or
  descends from it (a process snapshot each time it looks).
  `tests/guiapps.sh` passes the pid of the `zigsaw run` it started.

### Code map

| File | Change |
|---|---|
| `src/windows/zigsaw.rc`, `src/windows/zigsaw.manifest` (new) | version information, manifest |
| `build.zig`, `build.zig.zon` | `addWindowsResources` for the three programs; 0.22.0 |
| `src/info.zig`, `src/main.zig` | the "built" line; its tests run |
| `tests/winwait.zig`, `tests/guiapps.sh` | windows of the run only |
| `tests/install.sh`, `tests/published.sh` | version information; names in the catalog |
| `recipes/node.json`, `go.json`, `prettier.json`, `fzf.json`, `zot.json` | names, new pins |
| `README.md`, `docs/findings.md`, `docs/gaps.md` | the above |

## Results

### Tests

- Unit: 85 and 8 pass.
- `tests/install.sh`: 17 pass, on the package of the final sources.
- `tests/shims.sh`: all pass (with `SEED_DOWNLOADS`: without it, eight rows
  fail, as BusyBox's download is refused).
- `tests/guiapps.sh`: 15 pass, one known gap, 68 s.
- `tests/zot.sh bash tests/registry.sh`: all pass, with the matrix store's
  zot and with the newly pinned one.
- Not run: `tests/published.sh` (until the five images are republished),
  `build.sh`, the matrix, `gtk.sh`. Only resources, `info`'s wording and
  the tests changed.

### Reproducibility

| Image | Manifest | Was |
|---|---|---|
| `org.nodejs.node` 24.21.0 | `0a7a2c31` | `1094b9db` |
| `org.golang.go` 1.27.1 | `f8192fc2` | `426de395` |
| `io.prettier.prettier` 3.9.9 | `8eb376ad` | |
| `com.github.junegunn.fzf` 0.74.4 | `4d875925` | |
| `dev.zotregistry.zot` 2.1.21 | `970ce942` | |

The same in `D:\zs\a` and `D:\zs\b`, and their layers are those ghcr.io
has: only the configs changed. zigsaw 0.22.0's programs, from two checkouts
in different directories: `zigsaw.exe` `6cba3824…`, `zigsaw-shim.exe`
`b8e98d04…`, `zigsaw-shimw.exe` `0880c8cd…`.

## Decisions made along the way

- **Short descriptions.** Task Manager names a process by its file's
  description, so every shim would have shown a sentence.
- **`/:auto-includes` and `none` as two arguments**: zig's `rc` reads what
  follows the option's name as its value (`=none` is refused).
- **"Pinned downloads" rather than recording in the config whether an
  image was compiled**, which would have changed every image's digest.
- **A row for names in the catalog** rather than one for `search pdf`:
  published.sh already compared the catalog with the registry by id and
  version.

## Findings

See [findings.md](findings.md#other-findings).

## Known gaps

- zigsaw's programs aren't signed, and Defender's machine learning may
  still flag a build by what it does.
- Local Defender scans can't see `Bearfoos.A!ml` while it's allowed on
  this machine.
- Ten runtimes and SDKs without names in the catalog (see
  [gaps](gaps.md)).

## Suggested for iteration 23

- You: send the report to Microsoft
  (microsoft.com/wdsi/filesubmission, as a software developer, with
  `D:\zs\i20\bin\zigsaw.exe`; the text is in
  `D:\zs\i22\upstream\defender-fp.md`), and remove the "allow" for
  `Bearfoos.A!ml` in Windows Security if you'd like local scans to mean
  something again.
- Code signing for releases (SignPath Foundation, which is free for open
  source, or Azure's Trusted Signing).
- Flatpak's "extra data", Files at low integrity and in an AppContainer,
  and the rest suggested in [iteration 21](iteration-21.md#suggested-for-iteration-22).
