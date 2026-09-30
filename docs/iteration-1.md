# Iteration 1: a no-admin Flatpak for Windows

Concluded 2026-10-01.

## Outcome

Iteration 1 asked whether zigsaw can install and run real command-line
toolchains reproducibly on Windows, including Windows 11 Home, without admin
rights. **It can.** In the default `soft` sandbox, busybox, ripgrep, Git, Node
with npm, Python and the zig toolchain all work. Each gets a hermetic
environment, its own persistent data directory, and read-only app files. An
enforcing sandbox built on AppContainers works only for self-contained tools;
the [iteration 1 findings](findings.md) explain why.

Zigsaw can now:

- build apps from pinned JSON recipes into standard OCI images, the same
  inputs always giving the same digest;
- install them per user, with no admin rights and no Hyper-V;
- run them in a clean environment, with a job object that ends the whole
  process tree;
- put their commands on PATH as small `.exe` shims;
- publish them to, and install them from, any OCI registry.

## Starting decisions

These were set at the start of the iteration and held throughout:

| Decision | Choice |
|---|---|
| What runs inside | Windows programs (not Linux guests), modelled on Flatpak |
| Focus | Reproducibility first; security matters but is secondary |
| Privileges | No admin. Admin-only features were to be considered only if the no-admin approach failed; it didn't |
| Interface | Command line first; GUI apps later |
| Image format | OCI manifest with a zigsaw config type and plain tar layers |
| Recipes | JSON |
| App data | Persistent by default, `--ephemeral` for a fresh directory |
| Host files | Only with an explicit permission, including the working directory |

## What was built

The iteration ran as five slices, each ending in working, tested code.

1. **End-to-end skeleton.** `build`, `run`, `list` and `rm`; the local store
   (blobs, refs, deployments, per-app data); deterministic tar layers; the
   `soft` sandbox (clean environment, redirected profile folders, job object);
   and the `appcontainer` sandbox (per-app AppContainer profile, ACL grants
   that `rm` revokes).
2. **Compatibility matrix.** Six real tools, each in both sandboxes
   ([`tests/matrix.sh`](../tests/matrix.sh)). It answered the no-admin question
   and found one reproducibility hole: `soft` runs could modify installed app
   files. Fixed: deployed app files now deny writes and deletes to the user.
3. **Build speed.** Builds stream zip entries straight into the layer instead
   of unpacking to disk, and deployment extracts the layer with 4 parallel
   workers. Installing zig went from 60–175 s to about 16 s.
4. **Command shims.** Recipes declare `exports`. Each becomes
   `<store>\bin\<name>.exe`, a 127 KB copy of `zigsaw-shim.exe` with a sidecar
   file, that runs the app with the caller's arguments passed through exactly.
5. **Registries.** `zigsaw pull` and `zigsaw push`, with the OCI token flow
   for anonymous pulls (ghcr.io, Docker Hub) and login credentials for pushing
   and private images.

### Code map

| Area | Modules |
|---|---|
| CLI | `main.zig` |
| Image format | `oci.zig` (types, validation), `layer.zig` (tar layers), `zipfile.zig` |
| Building | `recipe.zig`, `fetch.zig`, `builder.zig` |
| Store | `Store.zig`, `install.zig` |
| Running | `run.zig`, `process.zig`, `acl.zig`, `appcontainer.zig` |
| Shims | `exports.zig`, `Sidecar.zig`, `shim.zig` (separate executable) |
| Registries | `Registry.zig` (client), `remote.zig` (pull and push) |
| Windows API | `win32.zig` |

About 3,900 lines of Zig with no dependencies beyond the Zig 0.16 standard
library.

## Results

### Measurements

Measured on the development machine (Windows 11 Home, 16 threads, Defender
real-time protection on):

| What | Time |
|---|---|
| Install zig (19.5k files, 378 MB) | 16.6 s, was 60–175 s |
| Install Node (2k files) | 3.4 s, was about 12 s |
| Rebuild an installed app (zig) | 3.7 s |
| Run overhead, `node -e 0` | 82 ms direct, 95 ms via `zigsaw run`, 109 ms via a shim |
| First AppContainer grant on zig's files | 2.7 s, once per app |

Installing a large app is bounded by Defender scanning each new file: about
8 s to create zig's files, and 3.6 s to protect them. Going further would need
a Defender exclusion or a Dev Drive, both of which need admin.

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 24 of 24 pass |
| [`tests/matrix.sh`](../tests/matrix.sh): 6 tools, 26 checks per sandbox | `soft`: all 26 as intended. `appcontainer`: 17 as intended, 9 known failures (see findings) |
| [`tests/shims.sh`](../tests/shims.sh) | 13 of 13 pass |
| [`tests/registry.sh`](../tests/registry.sh): local zot registry, ghcr.io, Docker Hub | 20 of 20 pass, including 5 login checks |

Every recipe rebuilds to an identical digest, and an image pushed and pulled
through a registry keeps its digest.

## Decisions made along the way

- **`soft` is the default sandbox; `appcontainer` is opt-in.** Windows blocks
  AppContainers from resolving real paths (the Mount Manager and the `C:\`
  root), which breaks Git, Node scripts, npm and zig. No setting zigsaw can
  change without admin fixes that.
- **Installed app files are protected with a deny ACE for the user.** It's the
  simplest way to keep every run reproducible without admin, and zigsaw keeps
  the owner's right to lift it on `rm`.
- **Everything that affects a digest is deterministic.** Tar entries are
  sorted, timestamps zeroed and modes fixed. Manifests are stored and
  transferred as the exact bytes that were hashed.
- **Shims are copied `.exe` files, not `.cmd` scripts.** Programs that start
  `node` or `git` directly find them, arguments aren't re-parsed by cmd, and
  Ctrl+C doesn't prompt "Terminate batch job?". Shims look up their export
  when they run, so updating an app never requires rewriting its shims.
- **Exports can prepend arguments with `${app}`.** Node's recipe runs npm as
  `node.exe npm-cli.js`, which avoids starting batch files.
- **Registry tokens only go to the registry's own host.** zigsaw follows
  redirects itself and drops the token when a download moves to another host,
  such as a CDN.
- **Credentials come from environment variables** (`ZIGSAW_REGISTRY_USERNAME`,
  `ZIGSAW_REGISTRY_PASSWORD`) for now. Registries on `localhost` use plain
  HTTP, as Docker does.

## Upstream issues found

Two bugs in Zig 0.16's `std.http.Client` turned up while building registry
support. Both are worked around in `Registry.zig` and are worth reporting
upstream:

1. With only `identity` enabled in `Request.accept_encoding`, the client writes
   a malformed `accept-encoding` header line, and Go servers reject the
   request with 400.
2. `RequestOptions.privileged_headers` are never written to the request, so
   an `Authorization` header passed that way is silently dropped.

## Known gaps

- **AppContainer compatibility.** Only self-contained tools work under
  `--sandbox=appcontainer`.
- **Batch files** can't be an app's command. They must be run through
  `--command=cmd`, or the program they wrap must be exported instead.
- **Global package installs** such as `npm install -g` fail, because the
  package manager's global prefix is the read-only app directory. Recipes have
  no way to point it at the data directory yet.
- **Shims** always run an app with its default options (no `--sandbox`).
- **The registry isn't isolated.** Apps that find folders with
  `SHGetKnownFolderPath` instead of environment variables would bypass the
  data-directory redirect; none of the tested tools do.
- **Store housekeeping.** Unused blobs are never garbage-collected, and a
  crashed build can leave files in `tmp\`.
- **Registries.**
  - Credentials come only from environment variables (no Docker config, no
    Windows Credential Manager).
  - Multi-platform indexes aren't supported.
  - Uploads are sent in one request, which very large layers may exceed on
    some registries.

Not yet tested:

- Ctrl+C during a run, directly or through a shim.
- Blob downloads that redirect to another host, as ghcr.io does for real
  images. The URL handling for this is unit-tested only.
- Apps with fixed install paths, installers, and GUI apps.

## Suggested for iteration 2

The platform works; what's missing is what makes it pleasant to use every
day. Suggested focus, in order:

1. **Publish the six recipes as images** to a public registry, so apps install
   with `zigsaw pull` instead of being built. This needs a decision on where
   the project's images live, such as a GitHub organization.
2. **`zigsaw update` and `zigsaw prune`.** Update re-pulls or rebuilds an app
   from the source its ref records. Prune garbage-collects blobs and cleans
   `tmp\`.
3. **Data-directory placeholders in recipe `env`**, so recipes can, for
   example, point npm's global prefix at the app's data directory.
4. **Verify Ctrl+C** in an interactive console, and redirected blob downloads
   against a real registry.

Two larger options can wait until usage asks for them: a low-integrity sandbox
that enforces writes (the findings describe how to probe it first), and GUI
apps.
