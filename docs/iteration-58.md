# Iteration 58: Zig 0.17

Built 2026-10-29. zigsaw **0.58.0**, built with Zig 0.17.0. Two new images
to publish: zig 0.17.0 and ZLS 0.17.0.

## Outcome

- **zigsaw is on Zig 0.17.0**: its code, its build, CI and the Release
  workflow. It builds itself in the new zig 0.17.0 image as the same bytes as
  `zig build -Dstrip` makes outside it, from any folder.
- **No published image changes.** 0.17's deflate makes 0.16's bytes, so
  zigsaw 0.58.0 rebuilds what's published as published (zig 0.16.0's image,
  manifest and all). A unit test now pins the gzip bytes, so a Zig whose
  deflate changes fails `zig build test` rather than every row of CI.
- **zig 0.17.0 and ZLS 0.17.0 images.** Recipes that build with zig keep
  their pins of zig 0.16.0's image; build.sh's fixtures, which build
  recipes/zig.json, are on 0.17.0.

## Starting decisions

From the planning session (plan file `let-s-plan-iteration-58-proud-scroll.md`):

- **Zig 0.17** (your pick, over signed images, shared registry logins or
  Neovim).
- **Only zig's and ZLS's images move** (your pick, over also moving the
  small zig-built apps, or every image built with zig): the 16 recipes with
  zig 0.16.0's image as an SDK keep it.
- **If 0.17's deflate had made other bytes, new digests for everything**
  (your pick, over keeping 0.16's deflate in zigsaw). It didn't, so nothing
  was re-digested.
- Mine: fixing what doesn't compile and what changes meaning, not every
  deprecation (`std.fmt.allocPrint`, `@intFromEnum`, `std.builtin`,
  `addWin32ResourceFile` stay for now).

## What was built

### Slice 0: probe

Facts in [findings](findings.md#zig-017-iteration-58) (scratch
`D:\zs\i58`): deflate's bytes against 0.16 on four published layers;
`zig rc` building resinator on first use (41 s, once a cache); `zig cc`,
`ar`, `ranlib`, the `as` alias and `dlltool` as before; ZLS 0.17.0's fetch
and offline build.

### Slice 1: zigsaw on 0.17 (0.58.0)

- [build.zig](../build.zig): `std.lang.Optimize`, `addPassthruArgs`;
  [build.zig.zon](../build.zig.zon): minimum Zig 0.17.0, version 0.58.0.
- `a ** n` in 31 tests → [src/testing.zig](../src/testing.zig)'s `repeat`;
  `dupeSentinel`, `field_names`/`field_values`/`field_types`,
  `findIgnoreCase`.
- [src/layer.zig](../src/layer.zig): the gzip bytes pinned, of the small test
  layer and a MiB of words in an LCG's order.

### Slice 2: zig 0.17.0's image, and zigsaw's build in it

[recipes/zig.json](../recipes/zig.json) at 0.17.0, env and aliases as they
were; [zigsaw.json](../zigsaw.json) pins it.

### Slice 3: ZLS 0.17.0

[recipes/zls.json](../recipes/zls.json): the tag, its vendor step's hash, and
zig 0.17.0's image as its runtime. [tests/zls.sh](../tests/zls.sh) checks
0.17.0.

### Slice 4: CI and documents

`setup-zig` 0.17.0 in [reproduce.yml](../.github/workflows/reproduce.yml) and
[release.yml](../.github/workflows/release.yml), which makes the push's run
check every group; [README](../README.md), [recipes](recipes.md),
[published apps](published-apps.md), [gaps](gaps.md),
[tests/self.sh](../tests/self.sh)'s header.

## Results

| check | result | time |
|---|---|---|
| 0.16 and 0.17 deflate, on zig's, MinGit's, GTK SDK's and TeX Live's layers | same bytes, each the published layer | |
| `zig build test` with 0.17 | 136 passed (134 + `repeat` + the pinned gzip bytes) | |
| zig 0.16.0's recipe, built by zigsaw 0.58.0 | manifest `f8310e4e`, as on ghcr.io | 53 s |
| zig 0.17.0's image, in store `p`, then in `p2` | manifest `93ec2b6b`, layer `a322613f` (91 MB) | 49 s |
| `zigsaw build` of the checkout in it, against host `zig build -Dstrip` | 4 programs the same bytes; also from a copy in another folder, cold cache | 223 s |
| ZLS 0.17.0, in `p`, then in `p2` | manifest `75b7d590` | 102 s |
| tests/zls.sh | 0 failed, 0 known gaps (soft, low, appcontainer) | 51 s |
| Defender scan of the 0.58.0 programs | no threats | |
| scripts/check-pins.sh on zig, ZLS, zigsaw.json | only the two 0.17.0 images missing (unpublished) | |
| build.sh's zig group (fixtures on zig 0.17.0: C, C++, `rc`, SQLite) | 36 ok, 0 failed | 5.6 min |
| build.sh's cmake-meson group (CMake, Meson, make) | 15 ok, 0 failed | 6.2 min |
| build.sh's langs group (Rust with dlltool and `as`, cgo, .NET, Java, PHP) | 53 ok, 0 failed | 9.8 min |
| build.sh's base group | 92 ok, 0 failed | 52 s |

## Known gaps

None new. `zig cc -###` still exits 1 (cgo's `-buildid=` stays). The gap on
deflate's bytes now says CI pins 0.17.0, guarded by the unit test.

## Next

- Publish **before pushing** (CI's self-build pulls zig's image, and its
  suites pull both), from store `D:\zs\i58\p` with
  `ZIGSAW=D:\zs\i58\bin\zigsaw.exe` (0.58.0):
  `scripts/publish.sh zig.json zls.json`. zig's `latest` moves to 0.17.0.
- Then commit and push, and I read the run: every group runs (the workflow
  changed), all with zigsaw built by 0.17.
- Then tag **v0.58.0**, and I read the Release run (tests/self.sh on the
  package, in zig 0.17.0's image).
- To build zigsaw on this machine: Zig 0.17.0 (winget's is 0.16.0).
- Later: the 16 zig-built recipes onto 0.17.0's image (Clang 22), with their
  workarounds re-checked.
