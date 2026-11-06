# Layer formats

Designed 2026-10-31; the [decisions](#decisions) were taken the same day.
The first slice was built in [iteration 64](iteration-64.md): stargazer
0.1.0, zigsaw's gunzip of every member, and measurements on Qt's layers. The
second in [iteration 65](iteration-65.md): the formats behind one interface
in zigsaw ([`src/format.zig`](../src/format.zig)), `"layer": "estargz"`, and
Qt's images on it. The third in [iteration 66](iteration-66.md): Range
downloads, updates that build the new blob from the old one, and
`zigsaw ls` and `zigsaw cat`.
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
  Nothing in this design trusts a blob unchecked. A lazy pull's download
  so far lives in `lazy\`, not `blobs\`, and moves in once it's checked;
  what it copied from the store's other blobs (iteration 79) is checked
  with the rest.
- **Formats are opt-in, per recipe.** The default stays gzip, and no
  existing image changes digest.
- **zigsaw decides by capability, not by format name.** Adding a format
  adds an implementation, not cases in the pull and update code.
- **No driver to install, no admin.** An app runs from a complete
  deployment, or, while `pull --lazy` downloads the layer, from Cloud Files
  placeholders, whose filter comes with Windows (iteration 77).

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
[`src/Store.zig`](../src/Store.zig) never name. Built in iteration 65 as
[`src/format.zig`](../src/format.zig): `Format.ofDescriptor` tells a layer's
format from its descriptor (an eStargz layer is `tar+gzip` with a TOC
digest), `write` makes a layer of a tree, and `deploy` unpacks one.
Iteration 66 added the one capability the update code asks for,
`Format.indexed()` (a per-file index; eStargz has one), and `openIndex`,
which opens a layer's index from any source and checks its TOC against the
descriptor.

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
- With prioritized files (below), it reads the tar where each of those is,
  then in order (`convertSource`, stargazer 0.4), and makes the same bytes as
  `stargazer convert --prioritized`. Without any, the bytes are the same as
  before there were any: a test pins them.

### Prioritized files

What a first run reads can come first in the blob, as eStargz allows:

- A recipe's `"prefetch"` lists files of its eStargz layer, as paths from
  the top of the app. They come first, in that order, each after its parent
  directories, then `.prefetch.landmark`, then everything else in its
  sorted order: Go's `WithPrioritizedFiles` layout, which the conformance
  check compares entry by entry.
- `scripts/record-prefetch.sh` makes the list: it pulls an image lazily
  into a store of its own, runs a command or opens a window once, and lists
  what each layer's helper fetched, in the order first asked for.
- A path the app doesn't have (a new version dropped it) is left out, with a
  warning, so that a version bump builds before its list is recorded again.
- A lazy pull's helper asks for the prioritized span at once, as soon as it
  starts, in parallel requests, and has Windows hydrate each file as its
  bytes are in, so that the first run finds them on disk.
- Only Qt's runtime and SDK have lists (iteration 78): 36 files of Qt's
  runtime for Designer's window, 456 of its SDK for a CMake build of a Qt
  program. Other eStargz images would need publishing again.

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

Built in iteration 66, for any pull or update of an indexed layer the store
lacks, when the store has blobs of other indexed layers (of any image it
keeps, apps' and builds'):

1. Read the new blob's tail with one Range request (1/64 of the blob,
   between 16 KiB and 1 MiB: most TOCs fit), its footer and TOC from it (a
   second request if the TOC is longer), and check the TOC against the
   `toc.digest` annotation of the manifest, which is itself checked.
2. Plan against the old blobs' TOCs, from `blobs\` (stargazer's
   `plan.make`): a member of the new blob is reused if a member of an old
   one has the same compressed length, the same chunk digest and size, and,
   for a file's last chunk, the same padding and the same entries after it
   up to the next payload, as the TOC gives them: their tar headers are in
   the member. Otherwise its bytes are fetched.
3. Coalesce the fetches (`plan.coalesce`): a gap of copies up to 64 KiB
   between two fetches is fetched too, then the shortest gaps until there
   are at most 64 requests. No multi-range requests: storage services
   behind registries don't all serve them.
4. If less than a tenth of the blob would be copied, download it whole.
5. Write the new blob from copied ranges, fetched ranges and the tail, in
   order, through one sha256, and check it against the manifest. If it
   differs, download it whole. A registry that answers a Range request with
   the whole blob (200) gets the same.

Reuse rests on the writer's determinism: the same file, after the same
entries, compressed by the same deflate, is the same member. The final
check is what makes it safe: the TOC can't prove the following headers
byte for byte.

What it saved, measured in iteration 66:

| update | blob | copied | fetched | requests |
|---|---|---|---|---|
| Qt's SDK, 3 files changed in place | 96.2 MB | 98.9% | 0.4% + 0.6 MB TOC | 3 |
| llvm-mingw 20261006 → 20261020 | 110.3 MB | 16.5% | 83.5% (incl. tail) | 14 |
| VSCodium 1.143.17183 → 1.143.17232 (a recovery release; `stargazer plan`, iteration 67) | 218.2 MB | 83.5% | 16.4% + 0.2 MB TOC | 17 |
| VSCodium 1.140.06880 → 1.143.17232 (monthly) | 218.2 MB | 24.6% | 75.3% + 0.2 MB TOC | 35 |

llvm-mingw's 5,115 unchanged files of 5,382 are mostly headers, 17% of the
bytes; its programs and Clang's runtime libraries all change between
releases.

### Reading one file

Built in iteration 66 as two commands rather than `info` flags:
`zigsaw ls <image>` lists the files of an image's indexed layers, and
`zigsaw cat <image> <path>` writes one, checked against its chunk and file
digests, looking in the app's own layer first, then its runtimes'. Each
reads the tail (footer and TOC) and the file's members: Qt's runtime is
listed in one request of 1 MiB, and a 10 KB file of it read in two, through
ghcr.io's redirect to its storage. A blob the store has is read from there.
A gzip layer is named as one that can't be read without pulling.

### zigsaws that don't know a format

- eStargz images need zigsaw 0.65 or later. Checked with the release
  binaries in [iteration 65](iteration-65.md), pulling a small eStargz
  image from a local registry:
  - **0.60.0 fails to unpack it**: `error: EndOfStream`, after inflating
    the first member. Nothing is installed or deployed, and 0.65 then
    pulls it into the same store.
  - **0.64.0 installs it, and the app runs**, but its deployment has
    `stargz.index.json` and `.no.prefetch.landmark` among the app's files.
    0.65 keeps that deployment, since its digest is the layer's, until it's
    deleted.
  - No image says which zigsaw it needs: decided in iteration 65, as
    0.60's failure is clean and 0.64's is harmless.
- Prioritized files change nothing for a reader: the TOC still follows the
  blob, entries need no order, and every reader since 0.65 skips both
  landmarks and makes parent directories itself. A blob's prioritized files
  only lose some of the delta an update would reuse, as they moved.
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

- **Keeping apps lazily**, beyond the download: iteration 77's `pull --lazy`
  is a bridge to a complete deployment (see
  [the experiment](experiment-cloud-files.md) for why). ProjFS needs admin to
  turn on, and gives a reader zeros when its provider dies mid-fetch.
- **zstd:chunked**: Zig's std has no zstd compressor. Its TOC fits the
  model; it can come when a compressor does.
- **SOCI**: keeps layers unchanged, but needs resumable gzip checkpoints.
- **An external TOC**: only lazy pulling would use it. Prioritized files
  came in iteration 78.

## Slices

| iteration | what |
|---|---|
| 64 | stargazer 0.1: TOC model, eStargz reader and writer, CLI, C ABI v0, fuzzing, Go conformance, CI on three OSes. zigsaw: `layer.gunzip` reads every member, the submodule cloned by https in CI. Sizes and times on Qt's layers |
| 65 | the format interface in zigsaw, tar and gzip behind it unchanged; `"layer": "estargz"`, descriptor annotations, pulls without an inflated tar; Qt's chain on eStargz, five images published again |
| 66 | Range downloads (and resuming a broken download); stargazer 0.2's update plans; updates that build the blob from the store's; `zigsaw ls` and `zigsaw cat`; llvm-mingw on eStargz |
| 77 | stargazer 0.3's chunk reads; `pull --lazy`, Cloud Files placeholders served by a helper until the blob is in; TeX Live on eStargz |
| 78 | stargazer 0.4's prioritized files; recipes' `prefetch`, and `scripts/record-prefetch.sh`; a helper that fetches in parallel and once; Qt's chain re-pinned to llvm-mingw on eStargz, with lists |

## Decisions

Taken 2026-10-31:

- Lazy running is out of scope for now. (Reversed 2026-11-06: lazy pulling,
  as a bridge, opt-in with `--lazy`; see [iteration 77](iteration-77.md).)
- stargazer has a Zig API and a C ABI.
- eStargz is opt-in per recipe, not a change of every image. It's also the
  proof that zigsaw can carry more than one layer format.
- stargazer is a library of seekable layer formats, not of eStargz alone.
- The recipe key is a plain string for now.
- Qt's chain is the first to use eStargz.
