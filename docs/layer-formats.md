# Layer formats

Designed 2026-10-31; the [decisions](#decisions) were taken the same day.
The first slice was built in [iteration 64](iteration-64.md): stargazer
0.1.0, zigsaw's gunzip of every member, and measurements on Qt's layers.
The formats themselves are written and read by
[stargazer](https://github.com/zigsaw-io/stargazer), a library of seekable
layer formats in [`stargazer/`](../stargazer) (a git submodule, MIT
licensed), for Zig and C. eStargz is its first format. The facts about
eStargz are from its [spec](https://github.com/containerd/stargz-snapshotter/blob/main/docs/estargz.md)
and containerd's Go package, `estargz`, at stargz-snapshotter v0.19.1.

## Before

What was so when this was designed:

- A layer is a tar file, gzip-compressed since [iteration 7](iteration-7.md),
  written deterministically: sorted entries, zero timestamps, fixed modes,
  a gzip header without a time or name, deflate at level 6
  ([`src/layer.zig`](../src/layer.zig)). A test pins the bytes Zig's deflate
  makes, because every image digest is what it makes of the layer.
- zigsaw unpacks `application/vnd.oci.image.layer.v1.tar` and
  `...tar+gzip`, mixed in one image if need be, and refuses any other layer
  type by name ("has a layer of type ..., which zigsaw can't unpack").
- A pull downloads up to 4 blobs at once into `blobs\`, inflates each gzip
  layer into a plain tar in `tmp\` on one thread, then extracts it into
  `deploy\<digest>\` with 4 workers. The inflated tar costs as much disk as
  the layer's files.
- An update downloads every layer whose digest changed, whole, however
  little in it changed. The old blob stays in `blobs\` until `zigsaw prune`.

## What eStargz is

- **A gzip-compressed tar that is a chain of gzip members.** A member
  starts at the top of the blob, at the top of each non-empty regular
  file's payload, optionally inside a large file's payload (a *chunk*,
  4 MiB in Go's writer), at the TOC's tar header, and at the footer. A
  member that starts at a payload also carries the payload's padding and
  every tar header after it, up to the next payload.
- **The TOC** is the last tar entry, `stargz.index.json`: JSON with
  `version` 1 and one entry per tar entry and per chunk (`name`, `type`,
  `size`, `mode`, `offset` of the member, `chunkOffset`, `chunkSize`,
  `digest` of the file, `chunkDigest` of the chunk, and more). Its digest is
  the sha256 of the JSON bytes. Go writes it with `MarshalIndent` and tabs.
- **The footer** is the last 51 bytes: an empty gzip member whose Extra
  field holds subfield `SG` with `%016xSTARGZ`, the TOC's offset. Legacy
  stargz (Google's CRFS) has a 47-byte footer without the subfield header.
- **A landmark** must be in the archive: `.no.prefetch.landmark`, a
  regular file holding the byte `0x0f`, which Go's builder puts first when
  no files are prioritized. Prioritized files, and `.prefetch.landmark`
  after them, are for lazy pulling's prefetch.
- **Two annotations** go on the layer's descriptor in the manifest:
  `containerd.io/snapshot/stargz/toc.digest` (required) and
  `io.containers.estargz.uncompressed-size`.
- **Go's verifier keys chunks by offset** and refuses one offset twice. So
  `innerOffset`, which packs several small payloads into one member, can't
  be verified there, and zigsaw doesn't write it.
- **The media type is plain `tar+gzip`.** A gzip reader that reads every
  member sees an ordinary tar, with the TOC and landmark as two extra files.

## What zigsaw's gzip did

From a probe on Zig 0.17: `std.compress.flate.Decompress` reads **one**
gzip member, then reports the end of the stream, without an error, leaving
the rest of the input unread. So:

- **zigsaw 0.60.0 can't read eStargz**: it inflates the first member (the
  landmark's tar header) and then fails, or deploys part of the tree. An
  eStargz image needs a zigsaw that knows it, unlike Docker, containerd and
  Go, which read every member.
- **A `.tar.gz` source of several members lost all but the first**,
  silently: bgzip makes such files, and so can pigz. Fixed in
  [iteration 64](iteration-64.md): `layer.gunzip` reads every member,
  ignores trailing zero bytes, as GNU gzip does, and fails on other
  trailing bytes.

## Principles

- **The same tree and recipe make the same bytes**, in every format.
- **A blob in the store is complete and checked against its digest.**
  Nothing in this design stores part of a blob, or trusts one unchecked.
- **Formats are opt-in, per recipe.** The default stays gzip, and no
  existing image changes digest.
- **zigsaw decides by capability, not by format name.** Adding a format
  adds an implementation, not cases in the pull and update code.
- **No filesystem driver, no admin**: an app runs from a complete
  deployment. Lazy running is out of scope.

## Design

### Formats and capabilities

| capability | formats | what it gives |
|---|---|---|
| sequential stream | tar, gzip | pulls as they are |
| seekable members | eStargz; later zstd:chunked | parallel decompression straight into the deployment, no inflated tar |
| per-file index | eStargz; later zstd:chunked | updates that download what changed; reading one file of a remote layer |

tar and gzip move behind the same interface first, with their bytes
unchanged (the pinned-deflate test doesn't move). eStargz is then a third
implementation, which [`src/remote.zig`](../src/remote.zig) and
[`src/Store.zig`](../src/Store.zig) never name.

### Stargazer and zigsaw

- **stargazer** owns the formats: the TOC model (eStargz's, general enough
  for zstd:chunked's, which derives from it), the eStargz reader and
  deterministic writer, and the plan for an update: two TOCs in, the byte
  ranges to copy and to fetch out. It does no networking (reads go through
  a read-at callback), keeps no store, and has no Windows code. A small CLI
  (`convert`, `ls`, `cat`, `verify`, `extract`) is for tests and use
  outside zigsaw.
- **zigsaw** owns the policy: which format a recipe asks for, Range
  requests, the store, ACLs, and every check against a digest.

### The writer

- The input is a tar stream, such as zigsaw's layer writer makes, and the
  output is eStargz. **Tar headers are kept byte for byte** (Go's
  `AppendTarLossLess`), so the archive is the input's entries with the
  landmark first and the TOC last.
- Members start at each payload and every 4 MiB inside one, as in Go's
  writer, and are compressed by Zig's deflate at level 6, as gzip layers
  are. A test pins the bytes, as for gzip.
- The TOC has Go's fields in Go's order, tab-indented, with Go's
  `omitempty` rules; zero times, ids and names are left out. The landmark's
  and the TOC's tar headers have mode 0, as Go's do.
- The input's end-of-archive blocks are left out, so a plain tar reader
  reaches the TOC's entry; Go's lossless mode keeps them ahead of it.
- `stargz.index.json`, `.prefetch.landmark` and `.no.prefetch.landmark` are
  reserved: a tree with one of them fails to build.
- `zigsaw build` of a recipe with `"layer": "estargz"` makes the same bytes
  as `stargazer convert` of the tar of its gzip layer.

### Recipes

- `"layer": "estargz"` picks the format; leaving it out means `"gzip"`. A
  plain string for now; an object with options (chunk size) can come later.
- The format is a build input: it's in the build cache key, and the
  Reproduce check rebuilds the same bytes.
- The layer's descriptor gets the two annotations, so other eStargz tools
  can use the image. `oci.Descriptor` gains `annotations` for this.
- First users: Qt's chain, `io.qt.Qt6.Sdk.Base`, `io.qt.Qt6.Sdk` and
  `io.qt.Qt6`, whose own layers are 37, 91 and 57 MB as gzip. Their CMake,
  llvm-mingw and BusyBox layers stay gzip, so the SDKs become mixed images,
  and Flameshot and Notes, which stay gzip, run on an eStargz runtime.
  Five images are published again.
- What it costs (iteration 64, converting the published layers): 39.0, 96.2
  and 58.4 MB, 4.8, 5.3 and 1.6% more, since each file's member starts its
  own deflate window. Converting took 3.6, 10.2 and 5.8 s.

### Pulling

- A worker per CPU, up to a cap, takes files from the TOC, decompresses
  each file's members from the blob straight into the deployment, and
  checks each chunk's digest. No tar is inflated.
- The TOC and landmark entries are not deployed, by either path: an
  eStargz layer read as plain gzip deploys the same tree.
- The blob is downloaded whole and checked first, as now; the chunk checks
  only catch a bad reader.
- **It saves disk, not time** (iteration 64, on Qt's layers): creating the
  files takes the time, and inflating one layer took 0.5 to 1.1 s of 2.8 to
  11.3. Qt's SDK, 10,196 files, took 11.3 s by zigsaw's path and 10.8 s
  through stargazer with the same 4 workers (9.5 s with 8). Not inflating
  saves its tar: 323 MB for that layer. Updates are where time can be saved.

### Updating

When a layer's digest changed and both the old and the new layer are
eStargz:

1. Read the new blob's footer and TOC with two Range requests, and check
   the TOC against the `toc.digest` annotation of the manifest, which is
   itself checked.
2. Plan against the old blob's TOC, from `blobs\`: a member of the new
   blob is reused if a member of the old one has the same compressed
   length, the same chunk digest, and the same tar entries following it up
   to the next payload. Otherwise its bytes are fetched.
3. Write the new blob from copied ranges, fetched ranges, the TOC and the
   footer, and check its sha256 against the manifest. If it differs, fetch
   it whole.

Reuse rests on the writer's determinism: the same file, after the same
entries, compressed by the same deflate, is the same member. The final
check is what makes it safe.

### Reading one file

`zigsaw info` can read a file of a remote layer, such as a licence or an
icon, through the footer, the checked TOC and the file's members, without
pulling the layer.

### zigsaws that don't know a format

- zigsaw 0.60.0 and older can't read eStargz (above). 0.64.0 reads every
  member, so it would deploy an eStargz layer, but with
  `stargz.index.json` and `.no.prefetch.landmark` as two files of the app's.
  eStargz images need the zigsaw of iteration 65 or later, which leaves
  them out. How 0.60.0 fails is checked with its release binary in
  iteration 65.
- A later format with a media type of its own, such as zstd:chunked
  (`tar+zstd`), is refused by name, as zstd is now.

### The C ABI

- Opaque handles, an `sg_` prefix, and no Zig types across the boundary.
- I/O through callbacks: `read_at(ctx, offset, buf, len)` and
  `write(ctx, buf, len)`. HTTP ranges are the caller's.
- Functions return a status; `sg_last_error()` gives the message of the
  calling thread's last failure. The library allocates; `sg_*_free`
  releases.
- `include/stargazer.h` is written by hand. A C program built against it
  with `zig cc`, on Windows, Linux and macOS in stargazer's CI, keeps the
  header and the exports in step.
- `zig build` makes a static and a shared library; `sg_version()` gives the
  library's version.
- v0: open a blob, list its entries, read a file, verify, convert a tar.
  Planning updates stays Zig-only until it settles.

### Not in this design

- **Lazy running**: needs a filesystem driver. ProjFS needs admin to turn
  on; the Cloud Files API is untested with AppContainer and low IL.
- **zstd:chunked**: Zig's std has no zstd compressor. Its TOC fits the
  model; it can come when a compressor does.
- **SOCI**: keeps layers unchanged, but needs resumable gzip checkpoints.
- **Prioritized files and an external TOC**: for lazy pulling only.

## Slices

| iteration | what |
|---|---|
| 64 | stargazer 0.1: TOC model, eStargz reader and writer, CLI, C ABI v0, fuzzing, Go conformance, CI on three OSes. zigsaw: `layer.gunzip` reads every member, the submodule cloned by https in CI. Sizes and times on Qt's layers |
| 65 | the format interface in zigsaw, tar and gzip behind it unchanged; `"layer": "estargz"`, descriptor annotations, pulls without an inflated tar; Qt's chain on eStargz, five images published again |
| 66 | Range downloads, updates that rebuild the blob, reading one remote file |

## Decisions

Taken 2026-10-31:

- Lazy running is out of scope for now.
- stargazer has a Zig API and a C ABI.
- eStargz is opt-in per recipe, not a change of every image. It's also the
  proof that zigsaw can carry more than one layer format.
- stargazer is a library of seekable layer formats, not of eStargz alone.
- The recipe key is a plain string for now.
- Qt's chain is the first to use eStargz.
