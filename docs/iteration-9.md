# Iteration 9: a low-integrity sandbox

Concluded 2026-10-05.

## Outcome

Iteration 8 found that AppContainer only suits self-contained tools: even
on the newest Windows 11, AppContainers can't look at directories that
grant them nothing, so `git init`, `npm install -g` and Node's
`fs.realpathSync` fail there. By hand, the same tools all worked at low
integrity, until an app had once run under AppContainer. Zigsaw now:

- **has a third sandbox, `--sandbox=low`**: the app runs at low integrity,
  with its data directory and the host paths it may write labelled low, so
  it can't write anywhere else. Every tool the matrix runs works in it,
  git, npm and zig builds included. Reading and the network stay open;
- **grants AppContainers access through a capability of each app's own**,
  instead of the AppContainer's SID, whose entries kept low-integrity
  processes out of the files entirely. Runs clear the old entries from what
  they use;
- **undoes labels with `zigsaw rm`**, keeping those other apps' runs still
  need, and labels it didn't make;
- **retries moving a build tool's cache** back into the store while Windows
  refuses for a moment.

The two upstream bugs from iteration 8 now have minimal reproductions,
outside zigsaw, on the latest releases. They are drafted for reporting.

No image changed, so nothing was republished.

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Scope | The low-integrity sandbox, and small fixes. Reading CI's probe output, shorter deployment paths, GUI apps and builds at low integrity wait |
| The default sandbox | `soft` stays the default; `low` is opt-in, by option or override, until the matrix is green under it on both Windows builds |
| Host paths a low run may write | Labelled low until `zigsaw rm`, which removes the label unless another app's runs still need it. Read-only grants need nothing |
| What zigsaw won't label | A drive's root, the user's profile, or a directory the profile is in: every low-integrity process could then write anywhere in it |
| The upstream reports | Drafted, with reproductions, for the user to file |

Decided during the iteration:

| Decision | Choice |
|---|---|
| What AppContainer grants go to (slice 1) | A capability derived from `zigsaw.<id>`, for each app's deployments, data and host paths, which only that app's runs hold. The plan's one zigsaw-wide capability for deployments would have let every zigsaw app read every deployment; this keeps them apart as before, at the same cost |
| Clearing the old entries (slice 1) | Any AppContainer package SID's from deployments, whenever a run uses them, and from data directories, in low and AppContainer runs: only zigsaw grants those. Only the app's own from host paths, which other programs may grant too |
| A label another app's runs made (slice 2) | Recorded for this app too, so removing either app keeps it for the other. A label zigsaw didn't make isn't recorded, so it stays |
| The order of the matrix's runs (slice 3) | soft, then appcontainer, then low, so each low run reads files an AppContainer run has just been granted |

The decisions of iterations 1–8 still hold.

## What was built

The iteration ran as four slices, each ending in working, tested code.

1. **AppContainer grants that don't hide files from low integrity.**
   - A probe first: Python's deployment copied, given one entry at a time,
     and run at low integrity (see Findings). Only an AppContainer's package
     SID keeps it out.
   - `appcontainer.zig`: each profile also has a capability SID
     (`DeriveCapabilitySidsFromName`); its runs hold it.
   - `acl.zig`: a grant can revoke other entries in the same change, and
     entries can be revoked by SID or for every package SID.
   - Deployments drop package SIDs' entries when a run uses them; data
     directories and host paths when the app next runs under AppContainer
     or at low integrity. `zigsaw rm` revokes both forms.
2. **`--sandbox=low`.**
   - `process.zig`: runs can start with another token; low runs get a copy
     of zigsaw's, labelled low, through `CreateProcessAsUserW`, with the same
     job object and stdio as before.
   - `acl.zig`: integrity labels, set with inheritance, read, and removed.
   - `run.zig`: `setUpLow` labels the data directory (or the `--ephemeral`
     one) and the paths the app may write, records the labels, and refuses
     drive roots and the user's profile.
   - `Store.zig`: the grants file also records labels, as `low <path>`
     lines, and can say whether another app records the same one.
   - `zigsaw rm` removes the app's labels, unless another app's are the
     same.
3. **The tests.**
   - `tests/matrix.sh`: a low column, run after AppContainer's.
   - `tests/sandbox.sh` (new): what each enforcing sandbox lets a busybox
     run write, the labels and grants zigsaw makes and records, labels two
     apps share, and what `rm` undoes. It runs in CI after `shims.sh`.
   - `tests/ctrlc.sh`, `shims.sh`, `batch.sh`: Ctrl+C, overrides and batch
     files at low integrity.
4. **Small fixes.**
   - `Store.renameRetrying`: moving a tool's cache, either way, retries for
     up to 5 s while Windows refuses.
   - Reproductions of zig's `cc -###` and Ninja's failure, outside zigsaw,
     on zig 0.16.0 and 0.17.0 and Ninja 1.13.2, and issue drafts.

### Code map

Changed since iteration 8:

| Area | Changes |
|---|---|
| Runs | `run.zig`: `setUpLow`, `labelRefusal`; AppContainer grants to the app's capability. `process.zig`: `lowIntegrityToken`, `SpawnSpec.token` |
| Security | `acl.zig`: `grant` with revocations, `revoke` by SIDs or package SIDs, `isPackageSid`, `labelLow`, `unlabel`, `ownLabel`. `appcontainer.zig`: capability SIDs, `packageSid`. `win32.zig`: tokens, labels, capability SIDs |
| Store | `Store.zig`: `Grant` with kinds, `grantedToOthers`, clearing package SIDs from deployments, `renameRetrying` |
| CLI | `main.zig`: `--sandbox=low`, `rm` undoing labels. `override.zig`: the `low` sandbox |
| Build | `builder.zig`: tool caches moved with retries |
| Tests | `sandbox.sh` (new). `matrix.sh`: the low column, `in_each`. `ctrlc.zig`: a low way, apps run from the work directory. `shims.sh`, `batch.sh`: low checks. `acprobe.zig`: uses `win32.zig`'s token bindings |
| CI | `tests/sandbox.sh` step |
| Docs | `findings.md`: which grants keep low integrity out, the low column |

About 8,870 lines of Zig in `src/` (8,355 after iteration 8). Still no
dependencies beyond the Zig 0.16 standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 59 of 59 pass (56 after iteration 8) |
| [`tests/sandbox.sh`](../tests/sandbox.sh) (new) | 28 of 28 pass |
| [`tests/matrix.sh`](../tests/matrix.sh) | 0 mismatches; 3 known gaps failed, all under AppContainer, as after iteration 8. The low column is as intended for all 42 checks |
| [`tests/ctrlc.sh`](../tests/ctrlc.sh) | 26 of 26 pass (20 before, plus the low run's six) |
| [`tests/store.sh`](../tests/store.sh), [`shims.sh`](../tests/shims.sh), [`batch.sh`](../tests/batch.sh) | All pass |
| `build.sh`, `registry.sh`, `published.sh` | Not run: nothing they cover changed, apart from tool caches' moves, which a rebuild of SQLite checked (same image, cache kept) |
| Reproduce workflow on GitHub | Not seen from here |

New checks:

- `sandbox.sh`: a low run writes its data directory, a path it may write
  (labelled, recorded, inherited by what it writes) and its working
  directory with the `cwd` permission; it can't write a read-only grant or
  anywhere else, and reads anywhere. It won't label the user's profile. An
  AppContainer grant names the app's capability, not its SID, and a low run
  after it reads what it wrote. Two apps share a label; a label made by
  hand isn't recorded. `rm` keeps the shared label, removes the app's own
  and what inherited them, revokes its AppContainer grants, and leaves the
  hand-made label; the second app's `rm` removes the shared one.
- `matrix.sh`: each check at low integrity, after AppContainer.
- `ctrlc.sh`: Ctrl+C, Ctrl+Break, the exit code, the process tree and
  closing the console through `zigsaw run --sandbox=low`.
- `shims.sh`: a low override keeps a shim from writing outside.
- `batch.sh`: batch files get their arguments exactly at low integrity.
- Unit tests: grant records of both kinds, and other apps' found by kind and
  path; which paths zigsaw won't label; a rename that waits while a file in
  the directory is held open.

Checked by hand:

- **The probe's grants**, one entry at a time, on copies of Python's
  deployment (see Findings).
- **The matrix store's migration**: a soft run cleared Python's deployment
  of the old entry; an AppContainer run granted the capability; Python
  started at low integrity before and after.
- **Labelling 20,000 files**, and granting them to an AppContainer.
- **Rebuilding SQLite** with zig's kept cache: 7 s, the same image, and the
  cache back in the store.

### Measurements

On the development machine:

| What | Time |
|---|---|
| Labelling 20,000 files low / granting them to an AppContainer | 2.2 s / 2.4 s |
| zig's first low run, labelling its data directory and cache | 9 s |
| `sandbox.sh`, seeded | 3 s |
| `ctrlc.sh` | 28 s |
| The matrix, warm | 109 s (60 s with two sandboxes) |

## Decisions made along the way

- **Each app's own capability rather than one for all of zigsaw.** Granting
  deployments to one shared capability would have saved an entry per app on
  shared runtimes, but let every zigsaw app read every other's files. A
  per-app capability keeps today's isolation, at today's cost.
- **Old entries are cleared where only zigsaw grants**: every package SID's
  from the store, but only the app's own from host paths, where other
  programs' AppContainers may have entries of their own.
- **Labels are explicit on the granted path**, even when it already
  inherits a low label from above, so removing the label above doesn't
  take this one away.
- **The guard's advice is "a directory inside it"**, not `cwd:ro`: an app's
  own permissions can only be added to, so `--filesystem=cwd:ro` wouldn't
  keep its `cwd` permission from labelling.
- **`ctrlc.sh`'s apps run in its work directory**, so its low runs label
  that, not the repository.

## Bugs found

In tests, caught before their slice was done:

- `sandbox.sh` matched grant records with `grep -iF`, which Git Bash's grep
  3.0 aborts on when the pattern has backslashes.

Upstream:

- **zig's `cc -###` still exits 1 in 0.17.0**, now failing to move the
  object file `-###` never wrote. The draft: a two-line reproduction, and
  why it matters to Go (see Findings).
- **Ninja 1.13.2's failure is narrower than iteration 8 thought.** A
  command that can't be started is reported as usual when it runs alone.
  When another command is running at the same time (`-j2` and two jobs),
  Ninja reports it and then dies with `ninja: fatal: ReadFile: The handle is
  invalid.` That's what happened in iteration 8's CMake build without a
  resource compiler, where it once crashed with `0xC0000409` instead.

## Findings

- **An entry for an AppContainer's package SID keeps low integrity out
  entirely.** A file or directory whose ACL allows a package SID
  (`S-1-15-2-` and seven numbers) can't be opened, listed or resolved by a
  low-integrity process outside that AppContainer, though the user has
  full access. Entries for `ALL APPLICATION PACKAGES`, `ALL RESTRICTED
  APPLICATION PACKAGES` and capability SIDs don't do that. Programs still
  start from such a directory, as the process starting them maps the file,
  but they can't load their DLLs or find their own path.
- **Low integrity works for every tool the matrix runs**, from a store
  whose deployments AppContainer runs have used: git `init`/`commit`, npm
  `install -g` and Node's `fs.realpathSync`, which fail under AppContainer,
  work at low integrity.
- **Labels propagate like grants.** Windows labels everything below a
  labelled directory, existing files included, and removing the label
  removes theirs. Files a low run creates inherit the label.
- **Ctrl+C reaches low runs as any other**: the app shares the console,
  whatever its token.
- **zig's `cc -###`** prints clang's commands, then goes on to collect an
  object file it never wrote, and fails. Go hashes the error, which names a
  new temporary file each time, into cgo builds' IDs.

## Known gaps

- **`--sandbox=low`** confines writing only: reads and the network stay
  open. Writing to the registry fails outside `HKCU\Software\AppDataLow`,
  though none of the tested tools did. Directories Windows labels low
  itself, such as `AppData\LocalLow`, can be written. Labels last until
  `zigsaw rm`, and any low-integrity program can write labelled paths
  meanwhile.
- **Grants an earlier zigsaw made** to an app's AppContainer SID on a host
  path keep other apps' low runs out of it, until that app runs under
  AppContainer again or is removed.
- **Builds** don't run at low integrity.
- **AppContainer**, as after iteration 8: on Windows 11 26300.9550,
  `git init`/`commit`, `npm install -g` and Node's `fs.realpathSync` fail;
  Windows Server 2025 denies `NUL`.
- The gaps from earlier iterations remain: cgo builds need `-buildid=`
  until zig's `cc -###` succeeds; Ninja's failure above; each blob up in
  one request; mounts only from where an app was pulled or a runtime's
  sibling repository; digests tied to the Zig zigsaw is built with; Go
  vendor steps that download every module; vendor steps' network access;
  builds one at a time on `B:`; MSVC images; Rust's need for zig and its
  store path limit; sources only from the default registry; pip-style
  launchers after updates; the registry not isolated; logins not from
  Docker's configuration; runtimes without runtimes.

Not yet tested:

- **The low sandbox on Windows Server 2025**, where CI runs the matrix and
  `sandbox.sh` as an administrator. The Reproduce run with this iteration
  wasn't seen from here.

## Suggested for iteration 10

1. **Read the Reproduce run**: the low column and `sandbox.sh` on Windows
   Server 2025, and the AppContainer probe's results there. Annotations
   (`::notice::`) are public, so the matrix could print the probe's lines as
   annotations to make them readable without logging in.
2. **File the two upstream reports**, and drop `-buildid=` from cgo recipes
   once zig's `cc -###` succeeds.
3. **Builds at low integrity**: a build could only write its build root and
   tool caches, which would catch tools writing outside them.
4. **Shorter deployment paths**, carried over again.
5. **Make `low` the default** if Server 2025 agrees with the development
   machine.
