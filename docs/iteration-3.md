# Iteration 3: trust and reach

Concluded 2026-10-02.

## Outcome

Iteration 2 made zigsaw practical to use every day. Iteration 3 fixed the
problem it found worst, a registry token leaking to every registry, and took
on the two next most useful items from its list. Zigsaw now:

- sends a registry's credentials only to that registry. `zigsaw login`
  checks a login with the registry and saves it per host in Windows
  Credential Manager. The environment variables, meant for CI and scripts,
  go only to the default registry;
- runs batch files as commands, with arguments that arrive exactly as given
  and can't run a command of their own. The commands of global npm packages,
  such as `tsc`, run with `zigsaw run --command=tsc org.nodejs.node`;
- has a CI workflow that builds the published recipes on a fresh Windows
  runner and compares them with the published images. Its first run was
  green: **the recipes build the same images on another machine.**

## Starting decisions

Set when the iteration was planned:

| Decision | Choice |
|---|---|
| Credentials | `zigsaw login` / `zigsaw logout`, saved per registry host in Windows Credential Manager (per user, no admin). The environment variables stay for CI and scripts, but only go to the default registry's host |
| CI | Verifies only: unit tests, then the published recipes built on a fresh runner and compared with ghcr.io. Publishing stays with `scripts/publish.sh`, run by hand |
| Batch files | Run through cmd.exe with quoting modelled on Rust's fix for CVE-2024-24576 ("BatBadBut"), as an app's command, an export, or `--command`. Putting commands installed at run time on PATH waits |
| Left out | More published apps, and revoking stale AppContainer grants |

The decisions of iterations 1 and 2 all still hold.

## What was built

The iteration ran as three slices, each ending in working, tested code.

1. **Credentials per registry.**
   - A new `credentials.zig` decides which credentials go where. Hosts are
     normalized: lowercase, no scheme or path, and `docker.io` for all of
     Docker Hub's names. A login is saved as the generic credential
     `zigsaw:<host>`.
   - `zigsaw login [--username=<user>] [--password-stdin] <registry>` asks
     for the password with the console's echo off, or reads it from stdin.
     It checks the credentials with the registry before saving them.
     `zigsaw logout` deletes the login.
   - Error messages name the `zigsaw login` to run, and say when the
     environment's credentials are set but belong to another registry. `-v`
     shows where a command's credentials came from.
   - Credentials are never sent to a token service over plain HTTP, unless
     the registry is on `localhost`.
2. **Batch files as commands.**
   - `buildBatchCommandLine` in `process.zig` runs
     `"<System32>\cmd.exe" /d /e:ON /v:OFF /c ""<script>" args..."`. `/d`
     skips the user's AutoRun commands, and `/v:OFF` keeps `!var!` literal.
     cmd.exe comes from System32, not `ComSpec`.
   - Arguments with anything outside a safe set of characters are quoted,
     `"` becomes `""`, and each `%` becomes `%%cd:~,%`, so `%VAR%` never
     expands. Arguments with a line break or NUL are refused.
   - `run.zig` routes `.cmd` and `.bat` commands through it. The job object,
     environment and sandbox are the same as for any app.
3. **CI reproducibility build.**
   - `.github/workflows/reproduce.yml` runs on pushes to `main`, pull
     requests and by hand, on `windows-2025`, with actions pinned to commit
     SHAs and read-only permissions. It runs the unit tests, then
     `tests/published.sh`, and uploads the logs if anything fails.
   - `tests/published.sh` compares each fresh build with the image tagged
     with the recipe's version. A version that isn't published yet is
     reported, not failed. The same version with a different digest fails,
     with a note saying whether the config, the files or both differ. It
     also checks that `latest` is the same image.

### Code map

New since iteration 2:

| Area | Modules |
|---|---|
| Credentials | `credentials.zig`; the login check and the HTTP realm rule in `Registry.zig`; Credential Manager and console bindings in `win32.zig` |
| Batch files | `buildBatchCommandLine` in `process.zig`, `Command.batch` in `run.zig` |
| CI | `.github/workflows/reproduce.yml`, `tests/published.sh` |
| Tests | `tests/batch.sh` with its app in `tests/batch/` and argument printer `tests/argv.zig`; batch cases in `tests/ctrlc.zig`; login checks in `tests/registry.sh` |

About 5,400 lines of Zig in `src/` (4,700 after iteration 2), plus the
490-line console test driver. Still no dependencies beyond the Zig 0.16
standard library.

## Results

### Tests

| Suite | Result |
|---|---|
| Unit tests (`zig build test`) | 34 of 34 pass (30 after iteration 2) |
| [`tests/matrix.sh`](../tests/matrix.sh): 6 tools, 28 checks per sandbox | `soft`: all 28 as intended. `appcontainer`: 17 as intended and 11 known failures, the same as iteration 2. The global npm check now runs the package's `.cmd` directly; it still fails under `appcontainer`, for the known reason |
| [`tests/shims.sh`](../tests/shims.sh) | 17 of 17 pass |
| [`tests/store.sh`](../tests/store.sh) | 15 of 15 pass |
| [`tests/ctrlc.sh`](../tests/ctrlc.sh) | 20 of 20 pass, 5 of them new: a batch file alone and through `zigsaw run` |
| [`tests/batch.sh`](../tests/batch.sh) (new) | 11 of 11 pass |
| [`tests/registry.sh`](../tests/registry.sh) against zot, with a second zot that requires a login | 35 of 35 pass. Iteration 2's one failure, the Docker Hub check with credentials set, now passes. 12 of the checks are new login checks |
| [`tests/published.sh`](../tests/published.sh), fresh store | 26 of 26 pass locally. All five images match fresh builds |
| Reproduce workflow on GitHub | Green for commit `5024d95`. The unit tests pass, and all five published recipes built to their published digests on the runner |

`tests/batch.sh` sends about 40 hostile arguments through an app's `.cmd`
command, an export, its shim, and `--sandbox=appcontainer`. They include
quotes, `%PATH%`, `& | < > ^`, attempts to run a command, and non-ASCII text.
All must come back byte for byte. The store's own path contains
`& ^ %PATH% ü`, so the batch file's path is tested too. To check the test
itself, the quoting was broken three ways on purpose (no `%` escaping in
arguments, CRT-style `\"` quoting, no `%` escaping in the script path). Each
made checks fail.

Checked by hand:

- **The login prompt**, in a pseudoconsole: the user name is echoed and the
  password isn't. After Ctrl+C at the password prompt, the console echoes
  again.
- **ghcr.io's answers to a token request without a scope**, which
  `zigsaw login ghcr.io` relies on (see Findings).

Every recipe still builds to the same digest, and no recipe changed.

### Measurements

| What | Time |
|---|---|
| `tests/published.sh` in a fresh store: build five recipes, pull and check five images | 89 s on the development machine |

## Decisions made along the way

- **A login is checked by asking for a token without a scope**, then asking
  for `/v2/` with it. That proves the credentials without naming a
  repository. A registry that doesn't ask for credentials at `/v2/` gets its
  login saved without a check, with a note, as Docker does.
- **The environment wins over a saved login** for the default registry.
  `zigsaw login` and `logout` say so when the variables are set.
- **Ctrl+C at the password prompt** gives "login cancelled". A console
  control handler turns the echo back on, even if zigsaw ends before its
  own cleanup runs.
- **Hosts must be valid host names.** Image references with other
  characters in the host are now refused when they're parsed.
- **A `%` in the batch file's own path is escaped too.** Rust's fix escapes
  only arguments. A store under a path with `%` in it would otherwise break,
  or expand variables.
- **Batch files work under `--sandbox=appcontainer`.** cmd.exe runs inside
  the AppContainer like any app.
- **`published.sh` tells "not published" from failure by the registry's
  answer:** "not found" for a missing tag, or "doesn't exist, or needs
  credentials" for a package that doesn't exist (or is private). Anything
  else fails.
- **The README links to the workflow's runs rather than showing a badge**,
  since the repository is private.

## Bugs found

None in earlier iterations' code. Two problems in new code were caught
before their slice was finished:

- After Ctrl+C at the password prompt, `login` reported "the password is
  empty". An interrupted read now cancels the login.
- The first injection check in `tests/batch.sh` passed even with CRT-style
  quoting. All the arguments went into one command line, and earlier ones
  changed cmd.exe's idea of what was quoted (see Findings). Each injection
  attempt now also runs on its own.

## Findings

- **ghcr.io and Docker Hub tokens.**
  - **ghcr.io:** a token request without a scope returns a token for a
    valid user and token, and 403 for a wrong token or none at all. `/v2/`
    then answers 200 with a user's token, and 403 with an anonymous one.
  - **Docker Hub:** answers wrong credentials with 401.
- **Ctrl+C and batch files.** When Ctrl+C reaches a batch file that is
  running node, node handles it first. cmd.exe then asks "Terminate batch
  job (Y/N)?". Answering Y ends the run with exit code 0xFF, both alone and
  through zigsaw. Through zigsaw, the run also ends the processes node left
  behind.
- **cmd.exe's quote state carries across arguments.** A `"` in one argument
  decides whether `&` in the next one is quoted. So a test that puts many
  hostile arguments in one command line can hide a quoting bug, and
  injection has to be tested one argument at a time. Inside quotes, `""`
  leaves the state as it was, which is why it's the escape for `"`.
- **The recipes reproduce across machines.** On GitHub's `windows-2025`
  runner, all five published recipes built to the published digests. That
  is the first evidence beyond the development machine.

## Known gaps

- **Commands installed at run time aren't on PATH.** `tsc` from
  `npm install -g` runs with `zigsaw run --command=tsc org.nodejs.node`, but
  has no shim.
- **Batch files.**
  - An argument with a line break can't be passed to one.
  - A batch file that turns on delayed expansion itself
    (`setlocal EnableDelayedExpansion`) expands `!var!` in its own
    arguments. Rust's fix has the same limit.
- **AppContainer compatibility.** Only self-contained tools work under
  `--sandbox=appcontainer`. Access granted to a host path lasts until the
  app is removed.
- **The registry isn't isolated.** Apps that find folders with
  `SHGetKnownFolderPath` would bypass the data-directory redirect.
- **Registries.**
  - zigsaw keeps its own logins. It doesn't read Docker's `config.json` or
    credential helpers.
  - `zigsaw login` needs a console to ask for the password; without one,
    use `--password-stdin`.
  - Multi-platform indexes aren't supported, and uploads go in one request.
- **CI covers the five published recipes only.** Zig's recipe isn't built
  there (its image is 378 MB). The end-to-end suites (matrix, shims, store,
  Ctrl+C, batch files, registry) still run only on the development machine.

Not yet tested:

- `zigsaw login` against registries other than zot, ghcr.io (the token check
  by hand) and Docker Hub (refused credentials only). Saving a real ghcr.io
  login was left to the user.
- Apps with fixed install paths, installers, and GUI apps.

## Suggested for iteration 4

1. **Shims for commands installed at run time**, so `tsc` works by name after
   `npm install -g`. For example: directories a recipe declares, or a
   `zigsaw export` command.
2. **More published apps**: Go, the .NET SDK, Temurin, Deno or uv. Each also
   tests zigsaw against another toolchain, and probes the
   `SHGetKnownFolderPath` gap.
3. **The end-to-end suites in CI.** `shims.sh`, `store.sh`, `batch.sh` and
   `ctrlc.sh` take about 30 s each and need no registry, so a runner could
   catch regressions that unit tests miss.
4. **Revoke stale AppContainer grants**, or probe the low-integrity sandbox
   that the [findings](findings.md) describe.
5. **Publishing from CI.** Now that builds reproduce on a runner, CI could
   publish a recipe's new version. Docker `config.json` credentials,
   multi-platform indexes and chunked uploads remain candidates too.

GUI apps can still wait until usage asks for them.
