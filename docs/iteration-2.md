# Iteration 2: everyday use

Concluded 2026-10-01.

## Outcome

Iteration 1 showed that zigsaw can install and run real command-line
toolchains reproducibly, without admin rights. Iteration 2 made it practical
to use every day. Zigsaw can now:

- install apps by id from published images: `zigsaw pull org.nodejs.node`
  fetches the image from `ghcr.io/zigsaw-io`, with the same digest as a local
  build of its recipe;
- update apps from where they came from, and clean up what no app needs any
  more, without breaking an app that is running;
- save run options for an app, such as `--sandbox=appcontainer`, which every
  run gets, including runs through its commands on PATH;
- let recipes keep state in the app's data directory, so `npm install -g`
  works.

Ctrl+C, Ctrl+Break and closing the terminal now have automated tests, and so
do registry redirects to a CDN. Both work.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Where images live | `ghcr.io/zigsaw-io/<app id in lower case>`, e.g. `ghcr.io/zigsaw-io/org.nodejs.node` |
| How they're published | A local script, run with a GitHub token. No CI yet |
| How they're named | By app id, through a default registry that `ZIGSAW_REGISTRY` overrides, like a Flatpak remote |
| Run options for commands on PATH | Saved per app (`zigsaw override`), like `flatpak override`, rather than per command |

Iteration 1's decisions all still hold: Windows programs, reproducibility
first, no admin, command line first, OCI images, JSON recipes, persistent
data, host files only by permission.

## What was built

The iteration ran as five slices, each ending in working, tested code.

1. **Data-directory placeholders.** Recipe `env` values, `path` entries and
   export arguments can use `${app}` and `${data}`. They're expanded each time
   the app runs, so an image stays the same on every machine. Node's recipe
   points npm's global prefix at `${data}\npm` and puts it on PATH, so
   `npm install -g` works. Before, it failed writing into the read-only app
   directory.
2. **`zigsaw update` and `zigsaw prune`.**
   - `update` rebuilds an app from its recipe file, or pulls its tag again,
     checking only the manifest when the tag hasn't moved. An app pulled by
     digest is pinned.
   - Installing a new version deletes the files of the version it replaces,
     unless that version is running.
   - `prune` deletes old blobs, deployments no app uses, and leftovers in
     `tmp\`. On request, it also deletes cached downloads and the data of
     uninstalled apps.
   - Locks let zigsaw commands run side by side, and keep anything a running
     app uses from being deleted.
3. **Per-app overrides.** `zigsaw override [options] <app-id>` saves run options
   that every run of the app gets. The command line wins over overrides, and
   overrides win over the app's own permissions. Shims run apps through
   `zigsaw run`, so they get overrides without any change.
4. **Registry shorthand and publishing.**
   - `zigsaw pull <app-id>[:tag]` and `zigsaw push <app-id>` use the default
     registry. The image has to hold the app it's named after.
   - `scripts/publish.sh` builds and pushes the recipes, and
     `tests/published.sh` checks what's published.
   - Five recipes are listed for publishing, and four of their images can be
     pulled from ghcr.io so far (see Results). Zig isn't published, at the
     user's request: its image is 378 MB.
5. **Ctrl+C.** A new test driver runs apps in a pseudoconsole, the way Windows
   Terminal hosts them, and sends real console events. zigsaw already behaved
   as intended. One race was found and fixed (see below).

### Code map

New since iteration 1:

| Area | Modules |
|---|---|
| Updating and cleaning up | `update.zig`, `prune.zig`, locks in `Store.zig` |
| Overrides | `override.zig`, shared option parsing in `main.zig` |
| Registry names | `expandShort` and `resolve` in `remote.zig` |
| Publishing | `scripts/publish.sh`, `scripts/published-recipes.txt` |
| Tests | `tests/store.sh`, `tests/ctrlc.sh` with its driver `tests/ctrlc.zig`, `tests/published.sh` |

About 4,700 lines of Zig in `src/` (3,900 after iteration 1), plus the
430-line test driver. There are still no dependencies beyond the Zig 0.16
standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 30 of 30 pass |
| [`tests/matrix.sh`](../tests/matrix.sh): 6 tools, 28 checks per sandbox | `soft`: all 28 as intended. `appcontainer`: 17 as intended, 11 known failures. That's iteration 1's 9, plus the two new `npm install -g` checks, which fail for the same reason |
| [`tests/shims.sh`](../tests/shims.sh) | 17 of 17 pass |
| [`tests/store.sh`](../tests/store.sh) (new): update, prune, locks | 15 of 15 pass |
| [`tests/ctrlc.sh`](../tests/ctrlc.sh) (new): console events, alone, via `zigsaw run`, via a shim | 15 of 15 pass |
| [`tests/registry.sh`](../tests/registry.sh) against a local zot | 22 of 23 pass. The Docker Hub check fails while registry credentials are set (see Findings) |
| [`tests/published.sh`](../tests/published.sh) against ghcr.io | BusyBox, ripgrep, MinGit and Node pass every check. Each one installs anonymously by id, has the digest of a local build, runs, and is up to date. Blob downloads were redirected to ghcr.io's CDN without the token. Python's image can't be pulled anonymously: it is missing, or still private |

Every recipe still builds to the same digest each time. Node's digest changed
once, when its recipe gained the placeholders.

### Measurements

| What | Time |
|---|---|
| Run overhead, `node -e 0`, median of 21 runs | 50 ms for node alone, 70 ms via `zigsaw run`, 81 ms via the shim |

That's about 20 ms over node alone through `zigsaw run`. Iteration 1 measured
about 13 ms with a different method; a run now also takes two locks and
reads the app's overrides.

## Decisions made along the way

- **"In use" is shown by locks, not by trying to move files.** The plan was to
  treat a deployment as in use if Windows refused to move it. But Windows
  moves a directory even while a program in it runs; it refuses only when a
  file in it is open. So each run holds a shared lock on
  `deploy\<hex>.lock` while the app runs, and a deployment is deleted only
  under an exclusive lock. It is moved into `tmp\` first, so a deletion cut
  short never leaves a partial app behind.
- **One store lock, held exclusively only by `prune`.** Commands that change
  the store hold `<root>\lock` shared, so they don't block each other. `run`
  holds it only while preparing the app, never while the app runs. `prune`
  needs it alone, because it deletes everything no app refers to, including a
  pull's blobs before the pull has written its ref.
- **Prune keeps only the files of a running version, not its blobs.** The
  blobs of a replaced version go at once; its deployment goes once the app
  exits.
- **Placeholders expand at run time.** That keeps them out of digests, and
  lets `${data}` mean the fresh directory of an `--ephemeral` run. Any other
  `${...}` text is left alone.
- **Overrides add and replace; they don't remove.** A filesystem path or
  variable given again replaces its earlier setting, and `--reset` clears
  them all. Overrides can't take away an app's own permissions. `rm` keeps
  them, like data, and `rm --delete-data` deletes them.
- **Images are named by the full app id, lowercased.** OCI repository names
  must be lowercase, so `org.git_scm.MinGit` lives at
  `.../org.git_scm.mingit`. Installed apps record the full reference, so
  `update` doesn't depend on `ZIGSAW_REGISTRY` later.
- **A missing image is reported as "doesn't exist, or needs credentials".**
  Registries such as ghcr.io answer both cases the same way, so as not to
  reveal which images exist.

## Bugs found

- **`zigsaw list >> file` overwrote the start of the file.** It dates from
  iteration 1. Zig 0.16's `File.writer` writes at file positions, starting
  at 0, so output appended to a file landed over its first line. stdout now
  uses `writerStreaming`.
- **An early Ctrl+C could end the app it was meant for.** zigsaw installed its
  Ctrl+C handler only after starting the app. A Ctrl+C in between would have
  ended zigsaw, and its job the app, before the app could react. The handler
  is now installed first.
- **A dangling pointer in a refactor.** When building stopped installing the
  image itself, the manifest's layer list still pointed into the builder's
  stack. The new store test caught it.

## Findings

- **Registry credentials go to every registry.**
  `ZIGSAW_REGISTRY_USERNAME` and `ZIGSAW_REGISTRY_PASSWORD` are offered to
  whichever registry asks for them. With a GitHub token set for publishing,
  pulling from Docker Hub fails, because Docker Hub refuses those
  credentials. Worse, the token is sent to Docker Hub's token service. This
  is why the Docker Hub check in `tests/registry.sh` fails while the
  variables are set.
- **Moving a directory on Windows** works while an exe inside it runs, and
  fails when a file inside it is open or a process's working directory is
  inside it. This is why zigsaw uses locks to detect use (above).
- **Closing the terminal** gives an app run through zigsaw the same time to
  clean up as when it runs alone. The app finished a one-second cleanup
  before the run ended, so zigsaw needed no change. Windows appears to
  deliver the close event to the most recently started process first; the
  tests show the effect, not the mechanism.
- **AppContainer access outlives its grant.** Under `--sandbox=appcontainer`,
  a host path stays accessible until the app is removed, even after the
  permission or override that granted it is gone. zigsaw adds ACL grants but
  never takes them back before `rm`, because concurrent runs could need
  different grants.
- **Testing console events** has its own traps. Git Bash starts programs with
  Ctrl+C turned off, and their children inherit that. ConPTY sends runs of
  spaces as cursor movements. The test driver deals with both.

## Known gaps

- **AppContainer compatibility.** Only self-contained tools work under
  `--sandbox=appcontainer`. Access granted to a host path also lasts until
  the app is removed (see Findings).
- **Batch files** can't be an app's command. That now matters more: the
  commands of global npm packages are `.cmd` files, so `tsc` has to run as
  `zigsaw run --command=cmd org.nodejs.node /c tsc`.
- **Overrides can't remove** an app's own permissions. An `--ephemeral`
  override has no opt-out for a single run, short of `--reset`.
- **The registry isn't isolated.** Apps that find folders with
  `SHGetKnownFolderPath` would bypass the data-directory redirect.
- **Registries.**
  - Credentials come only from environment variables, and are offered to
    every registry (see Findings).
  - Multi-platform indexes aren't supported.
  - Uploads go in one request. A 378 MB layer worked with zot.
- **Python isn't installable from ghcr.io yet.** Its package needs
  publishing, or making public.
- **Reproducibility across machines** is still unverified. Published images
  match the builds on the development machine, but no other machine has
  built the recipes yet.

Not yet tested:

- Apps with fixed install paths, installers, and GUI apps.

## Suggested for iteration 3

1. **Credentials per registry**, so a token only ever goes to the registry
   it's for. For example: a variable naming the registry the credentials
   belong to, or Docker's `config.json`. This comes first because it leaks
   tokens today.
2. **Batch files as commands**, started through `cmd.exe` with quoting that
   can't be escaped. Then the commands of npm and pip packages, and many
   Windows tools, run directly. This is the most common friction left.
3. **A CI build of the published recipes** on a fresh Windows runner, checking
   that its digests match the published ones. That would be the first
   evidence that builds reproduce across machines, and CI could take over
   publishing.
4. **Revoke stale AppContainer grants**, so access always matches the current
   permissions and overrides. Alternatively, probe the low-integrity sandbox
   that the [findings](findings.md) describe.
5. **More published apps.** Each new recipe also tests zigsaw against another
   toolchain.

GUI apps can still wait until usage asks for them.
