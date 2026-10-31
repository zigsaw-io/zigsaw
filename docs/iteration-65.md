# Iteration 65: layer formats in zigsaw, and Qt on eStargz

Built 2026-10-31. zigsaw **0.65.0**: layers are written and unpacked through
one interface, [`src/format.zig`](../src/format.zig), and a recipe can ask
for eStargz (`"layer": "estargz"`). Five images to publish: Qt's three, now
eStargz, and Flameshot and Notes, on the new runtime. stargazer's red fuzz
job is fixed (CI only, no new version). The design is
[layer-formats.md](layer-formats.md).

## Outcome

- **zigsaw writes and unpacks eStargz.** A recipe's `"layer": "estargz"`
  makes the app's own layer eStargz, through stargazer, and its descriptor
  carries the two annotations other eStargz tools read. A pull unpacks it
  straight from the blob, through the TOC, with 4 workers, checking every
  chunk, and inflates no tar. tar and gzip are behind the same interface,
  with the same bytes: the pinned deflate test didn't move, and neither did
  Flameshot's and Notes' own layers.
- **The bytes are stargazer's**: a zigsaw build with `"layer": "estargz"`
  is exactly `stargazer convert` of its gzip build's tar, for a small
  fixture and for Qt's three layers, which are what converting iteration
  62's published layers predicts. containerd's Go package reads the
  fixture's layer and checks its chunks.
- **Qt's chain on eStargz**: the base, SDK and runtime layers are 4.8, 5.3
  and 1.6% bigger than as gzip. They reproduce (iteration 62's trees), and
  tests/qt.sh passes on them, Flameshot and Notes included.
- **Pulling Qt's SDK saves its 323 MB tar, not time**: its layer unpacked
  in 12.2 and 11.5 s, against 11.3 s by the gzip path in iteration 64
  (inflating 1.1 of it).
- **zigsaws before 0.65 and eStargz**: 0.60.0 fails cleanly
  (`error: EndOfStream`, nothing installed); 0.64.0 installs the image and
  it runs, with eStargz's two files in its deployment. No guard (below).
- **stargazer's fuzz job was red from the start, and fuzzed nothing**: the
  Debug build Zig 0.17 makes on x86-64 Linux, with Zig's own backend, isn't
  instrumented for coverage, so the fuzzer ran blind and its report then
  failed (`pcs_len was zero`). Even `zig init`'s template fails so.

## Starting decisions

From the plan, the same day:

- Yours: **no guard for older zigsaws**: check how 0.60.0 and 0.64.0 meet an
  eStargz image, with their release binaries, document it, and add a guard
  only if 0.60.0 deployed part of a tree without an error. It didn't.
- Mine: the format in a new file that's the only one to name formats; the
  eStargz writer converts a temporary tar, so that the layer is
  `stargazer convert`'s by construction.

Decided during (mine):

- **The fuzz job in ReleaseSafe, 20K runs**: 3 minutes with the build, and
  2,504 of 15,877 PCs covered, against 2,615 for 200K runs in 16 minutes.
  ReleaseSafe keeps the safety checks fuzzing needs. No stargazer code
  changed, so it stays 0.1.0.
- **Capabilities later**: `Format` has no capability flags yet. The deploy
  path is one switch in format.zig, and the flags come with the update
  code that uses them (iteration 66).
- **zigsaw's own rules for names**, before stargazer extracts: an entry's
  name as the tar has it must pass `oci.isSafeRelPath`, as on the tar path,
  and be a file or directory. stargazer would clean `a/../../b` to `b`;
  zigsaw refuses it, as for a tar.
- **The TOC is checked against the descriptor's `toc.digest`** on every
  deploy, though the blob's digest was checked already: iteration 66's
  updates will rely on it.
- **The fixture is in tests/registry.sh**, which already pushes and pulls
  busybox through zot, not in tests/build.sh.
- **No second fresh-store build of Qt**: each of the three layers equals
  the conversion of the published one, which shows the trees reproduced;
  CI's Qt groups rebuild them against what's published.

## What was built

### zigsaw

- `src/format.zig`: `Format` (`tar`, `gzip`, `estargz`) with
  `ofDescriptor` (eStargz is `tar+gzip` with a TOC digest annotation),
  `label` and `mediaType`; `write`, which makes a layer of a tree and
  returns its annotations; `deploy`. Tests: formats by descriptor, eStargz
  bytes pinned, the same tree from gzip and eStargz (and, read as plain
  gzip, the two extra files a zigsaw that doesn't know eStargz deploys), a
  wrong TOC digest, unsafe names, reserved names.
- `oci.Descriptor` has `annotations`, left out when there are none (a test
  pins a descriptor's JSON). `oci.Compression` and `layerCompression` are
  gone.
- `Store.deploy`, `Tree.writeLayerFile`, the builder and `oci.validateLayers`
  go through format.zig. A runtime's layer descriptor is copied with its
  annotations into its apps' manifests.
- `recipe.Recipe.layer` (`gzip`, the default, or `estargz`). It's in the
  build cache key, as the recipe's bytes are.
- `zigsaw info` shows a `layer` line when the app's own layer isn't gzip.
- build.zig.zon depends on `stargazer/` by path.
- tests/registry.sh: 6 rows for an eStargz busybox (descriptor, push,
  pull without inflating, runs, deployment without the TOC or landmark,
  info).
- 0.65.0, here and in zigsaw.json.

### stargazer

- `.github/workflows/ci.yml`: the fuzz job builds in ReleaseSafe and runs
  20K inputs per test.

### Recipes

- `"layer": "estargz"` in qt6-sdk-base, qt6-sdk and qt6; the pins of the
  new base, SDK and runtime in qt6-sdk, qt6, flameshot and notes.
- Docs: recipes.md (`layer`, Qt), layer-formats.md (the interface, older
  zigsaws).

## Results

| check | result | time |
|---|---|---|
| zigsaw unit tests | 134 ok, the pinned deflate bytes among them; one run of seven failed while a Qt build loaded the machine, unseen, and the binary passed five times more | |
| stargazer fuzz, WSL (Zig 0.17.0 Linux) | Debug: `pcs_len was zero`, at 1K as at 200K, and for `zig init`'s template; ReleaseSafe 20K: ok | 2 min 50 s cold |
| eStargz busybox fixture | `stargazer verify` ok; Go `estargz` (conformance `check`) ok; `stargazer convert` of the gzip build's tar: the same blob, `573f5431` | |
| tests/registry.sh under zot | 92 ok, 0 failed, the 6 eStargz rows among them; the two runs before failed only the new deployment row, which counted a run's `.lock` file (fixed) | 5 min |
| zigsaw 0.60.0 pulling it | `error: EndOfStream`; nothing installed or deployed; 0.65 then pulls it | |
| zigsaw 0.64.0 pulling it | installed, runs; deployment has `stargz.index.json` and `.no.prefetch.landmark` | |
| Qt SDK base, eStargz | layer `1dbc21f9`, 38,992,915 B (gzip 37,201,787: +4.8%); manifest `826fa4ee` | 16 min |
| Qt SDK | layer `5ed0cb10`, 96,189,952 B (91,344,842: +5.3%); manifest `25ddeefd` | 18.5 min |
| Qt | layer `acb4a718`, 58,363,079 B (57,428,701: +1.6%); manifest `5b3217ab` | 21 s |
| Flameshot / Notes | manifests `3ed6acec` / `f8b72328`; own layers unchanged (`f5600604` / `7333408e`) | 1.5 min / 56 s |
| predicted layers (iteration 62's, converted by stargazer now) | all three the same | |
| iteration 64's conversions | base differed: made before the landmark's mode became 0 (0664 then) | |
| tests/qt.sh, store p | 0 failed | 1 min 52 s |
| pulling Qt's SDK from zot, twice | own layer unpacked in 12.2 and 11.5 s, no inflate; whole deploy 27.1 and 26.8 s | |
| tests/self.sh, with stargazer a dependency | 0 failed: zigsaw built by zigsaw the same bytes as `zig build -Dstrip`, and incrementally as with `--clean` | 10 min |

## Next

- **Commit stargazer first** (the CI file), push it, and I read its CI:
  the fuzz job should be green in about 3 minutes.
- **Publish before pushing zigsaw** (CI's Qt groups compare their builds
  with ghcr.io, and qt-suites pulls them), from store `D:\zs\i65\p` with
  `ZIGSAW=D:\zs\i65\bin\zigsaw.exe`, so each build is the cached one:
  `scripts/publish.sh qt6-sdk-base.json qt6-sdk.json qt6.json flameshot.json notes.json`.
- Then commit zigsaw with the new submodule commit, push, and I read the
  Reproduce run (Qt groups, qt-suites, the suites job's registry.sh).
- Tag **v0.65.0** after the push.
- Iteration 66: Range downloads, updates that rebuild the new blob from the
  old one and fetched members, and reading one file of a remote layer.
