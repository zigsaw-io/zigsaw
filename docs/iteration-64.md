# Iteration 64: stargazer, a library of seekable layer formats

Built 2026-10-31. zigsaw **0.64.0**: `layer.gunzip` reads every gzip member.
Nothing to publish. [stargazer](../stargazer) 0.1.0, a new git submodule
(`zigsaw-io/stargazer`, MIT), writes and reads eStargz; zigsaw doesn't use it
yet. The design is [layer-formats.md](layer-formats.md).

## Outcome

- **stargazer 0.1.0 writes and reads eStargz**, for Zig and for C, and
  builds for Windows, Linux and macOS:
  - a deterministic writer that keeps tar headers byte for byte, pinned by
    a test, as gzip layers are;
  - a reader through a read-at callback, which checks every chunk's
    digest;
  - a strict verifier: entries match the TOC, and every gzip member starts
    where the TOC says;
  - parallel extraction, a CLI, and a C ABI with a hand-written header that
    a C program checks.
- **containerd's Go package agrees, both ways**: Go's reader verifies
  every chunk of a blob stargazer made, stargazer's verifier passes one Go
  made, and both list the same tree with the same bytes.
- **zigsaw's gzip read one member only.** Zig's decompressor stops after
  the first member without an error. So zigsaw 0.60.0 can't read eStargz,
  and a `.tar.gz` source of several members would have lost all but its
  first, silently. `layer.gunzip` now reads every member, ignores zero
  padding, and fails on other trailing bytes. None of the 70 gzip sources
  in this machine's download caches has a second member or trailing bytes,
  so no build changes.
- **On Qt's layers, eStargz costs 1.6 to 5.3% in size and saves no time
  pulling**: creating files dominates, not inflating. What it saves on a
  pull is disk, the inflated tar: 323 MB for Qt's SDK. Deltas
  (iteration 66) are where the time will come from.

## Starting decisions

From the brainstorm, the same day:

- Lazy running out of scope for now; a Zig API and a C ABI; eStargz opt-in
  per recipe, and the proof that zigsaw can carry more than one layer
  format; stargazer a library of seekable layer formats, not eStargz's
  alone; `"layer": "estargz"`, a plain string; Qt's chain first.
- Mine: delta updates rebuild the whole new blob and check its digest,
  rather than trusting the TOC annotation, so the store keeps only whole,
  checked blobs.

Decided during (mine):

- **The gunzip fix in this iteration**, not with the format interface:
  it's a latent bug for sources, and eStargz needs it.
- **Go's layout where the spec leaves a choice**: the no-prefetch landmark
  first, with mode 0 like the TOC's header; members at each payload and
  every 4 MiB; Go's TOC fields, order and tab indentation. **Not Go's**:
  deflate level 6 (zigsaw's, not Go's 9); the reserved names refused in
  the input (Go drops an existing TOC); the input's end-of-archive blocks
  dropped (Go's lossless mode keeps them ahead of the TOC, where a plain
  tar reader stops).
- **No `innerOffset` packing**: Go's verifier keys chunks by offset and
  refuses one offset twice.
- **Strict verification reads the whole blob** with a multi-member reader
  that notes where each member starts, then checks the starts the TOC
  implies against the real ones.

## What was built

### stargazer 0.1.0

- `src/Source.zig`: blobs read at offsets (bytes, files, callbacks), and a
  stream over a range of one.
- `src/gzip.zig`: every member of a gzip stream, noting where each starts.
- `src/tar.zig`: tar entries with every header byte kept (ustar, GNU long
  names, pax, base-256 numbers, both checksums); global pax headers and
  sparse files refused.
- `src/Toc.zig`: the TOC model, eStargz's with zstd:chunked's `endOffset`,
  written exactly as Go's `MarshalIndent` writes it.
- `src/estargz.zig`: the footer (and legacy stargz's), `convert`, and
  `Reader`: `open`, `lookup`, `readFile`, `extract`, `verify`. A hostile
  blob can't make it allocate what the TOC claims, overflow, or write
  outside the directory.
- `src/main.zig`: `stargazer convert | info | ls | cat | verify | extract |
  version`.
- `src/c.zig`, `include/stargazer.h`, `tests/c/smoke.c`: the C ABI
  (`sg_convert`, `sg_reader_*`, `sg_last_error`, `sg_version`). On Windows
  the static library is `stargazer_static.lib`, since the DLL's import
  library is `stargazer.lib`.
- `conformance/`: a Go program on `estargz` v0.19.1 (`mktar`, `build`,
  `check`) and `run.sh`, which checks both ways.
- `.github/workflows/ci.yml`: tests on three OSes, conformance, and
  `--fuzz=200K` on Linux.

### zigsaw

- `src/layer.zig`: `gunzip` reads every member; a test with members of
  several deflate blocks, padding and trailing bytes. The pinned deflate
  test is unchanged.
- `.gitmodules` clones stargazer by https, and every CI checkout has
  `submodules: true`. zigsaw's own build walks the submodule as a
  repository of its own, with its `.gitignore`.
- 0.64.0, and [layer-formats.md](layer-formats.md).

## Results

| check | result | time |
|---|---|---|
| stargazer unit tests | 17 ok, the two fuzz targets once each, and 300 damaged blobs and 300 lying TOCs from a fixed seed | 7 s |
| `zig build test-c` | ok, built with `-Wall -Wextra -Werror` | |
| conformance/run.sh (Go 1.26.5 here) | ok both ways: 13 entries, the same listing from either reader, the same bytes | |
| cross builds | x86_64-linux-musl, aarch64-linux-gnu, aarch64-macos, x86_64-macos, x86-linux-musl | |
| `zig build test --fuzz` | not implemented for Windows in Zig 0.17; CI's Linux job does it | |
| zigsaw `layer.zig` tests | 35 ok, the pinned deflate bytes among them | 8 s |
| zigsaw unit tests | ok; the first run failed once in the folder tests, then passed, and that binary's 128 tests passed three times more | 22 s |
| Qt's layers as eStargz: base / SDK / runtime | 37.2 → 39.0 MB (+4.8%), 91.3 → 96.2 MB (+5.3%), 57.4 → 58.4 MB (+1.6%) | convert 3.6 / 10.2 / 5.8 s |
| converting again | the same digests | |
| `stargazer verify` | ok: 4,368 / 10,214 / 1,990 gzip members | 0.6 / 1.5 / 0.8 s |
| extracting the SDK (10,196 files): zigsaw's inflate + 4 workers / stargazer, 4 workers / 8 | 11.3 s (inflate 1.1) / 10.8 s / 9.5 s | |
| extracting base and runtime: zigsaw / stargazer | 4.2 / 4.9 s (stargazer ran first, against a cold Defender cache); 2.8 / 2.2 s | |
| extracted trees | identical to zigsaw's, for all three | |

## Next

- **Commit stargazer first**, in its own repository, and push it: zigsaw's
  commit records the submodule's commit, which CI clones. Then in zigsaw,
  `git add .gitmodules stargazer`, commit and push, and I read both runs
  (stargazer's first CI, and zigsaw's checkouts with the submodule).
- Tag **v0.64.0** after the push: zigsaw changed.
- Iteration 65: the format interface in zigsaw, with tar and gzip behind
  it unchanged; `"layer": "estargz"`, the descriptor's annotations, pulls
  without an inflated tar; how zigsaw 0.60.0 fails on an eStargz image,
  checked with its release binary; Qt's chain on eStargz, five images
  published again.
