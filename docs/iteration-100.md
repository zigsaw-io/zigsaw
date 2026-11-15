# Iteration 100: Several apps, one build

Started 2026-11-15, from "plan to implement compose-style multi-app build support".
`zigsaw build` built one recipe: a file, or a project's `zigsaw.json` (iteration 26). A
project made of several apps had to be built by hand: build the engine, copy its digest
into the recipes that use it, then build those. That digest changes every time the engine's
files change, as a directory source is hashed as the build takes it.
[`scripts/rebuild.sh`](../scripts/rebuild.sh) does the same for this repository's recipes,
rewriting pins with sed. Now **a project's `zigsaw.json` can list its apps, and `zigsaw
build` builds and installs them all, each after those it uses, as `docker compose build`
builds a compose file's services.** An app names another of the project by its id, with no
digest, and gets the image the project built. zigsaw is **0.100.0**. No recipe or image
changes, so there's nothing to publish. How it's used is in
[the README](../README.md#a-project-of-several-apps), and the rules are in
[recipes](recipes.md#several-apps).

State at the start: 99 had been pushed (`ea87978`, Reproduce 43554124664 green, `tests/exec.sh`
too). It has no tag yet.

## Outcome

- **A `zigsaw.json` with `"apps"`**, a list of paths inside the project's directory, each a
  recipe or a directory with a `zigsaw.json`, in place of being a recipe:
  `{ "apps": ["engine", "web", "tools/cli.json"] }`. `zigsaw build` in the directory (or
  given it, or the file) builds them all: "building 3 apps: org.example.engine,
  org.example.web, org.example.cli", then each app's usual lines.
- **An app names another by its id, unpinned**, as its SDK, a runtime or a module's
  `image`: `"runtimes": { "engine": "org.example.engine" }`, or `org.example.engine:1.2`
  with its version. The build gets the image the project built of that app, as if pinned to
  it. The recipes aren't touched.
- **Its image records the digest** (`runtimes`, `build.sdk`, `build.images`), as it would a
  pin's. With nothing changed, every app is the image built before. A changed engine makes a
  new engine, and new images of what uses it, and nothing else. A module in a kept build whose
  SDK, runtime or image changed is built again.
- **Order**: each app after those it names so; of those that could go next, the one listed
  first.
- **One app built alone** (`zigsaw build web`, or `zigsaw update org.example.web`, which
  builds the recipe its install records) finds its project: from the recipe's directory up,
  the first `zigsaw.json` with `"apps"` that lists it. The project builds the apps it uses
  first, and doesn't install them: "org.example.web uses org.example.engine, which its
  project builds first; it isn't installed". zigsaw looks only when the recipe names another
  app unpinned, so other recipes build as before.
- **Refused before anything builds**: apps that name each other in a circle (named), a path
  outside the project's directory, a project among the apps, two apps of one id, one listed
  twice, a tag that isn't the app's version, an app that names itself unpinned, anything
  else in the project's `zigsaw.json`, and unpinned references that aren't the project's
  apps (with the usual "pin it with" message). `--clean=<module>` is refused on a project:
  give the app's directory.
- **The build stops at the first app that fails.** Those before it stay installed, and the
  next build takes them from the cache. `zigsaw ps` lists each app's build as it goes, and
  stopping one ends the project's build there.

## Decisions

Yours, by the question dialog:

- **Building only.** `up`/`down` (running the apps together) wait.
- **Another app is named by its id, unpinned, and pinned in memory**, over zigsaw rewriting
  the pins in the recipes as rebuild.sh does, or a lock file.
- **The list is the root `zigsaw.json`'s `"apps"`**, as a Cargo workspace's, over a compose
  file of its own.

Mine:

- **Apps are named by their recipes' ids**, with no names of the project's own, so there's
  one name for each.
- **The recipe is pinned before anything reads it** (`compose.pin`): the references become
  `"<id>:<version>@sha256:<digest>"`, the form rebuild.sh writes. So `deps.resolve`, the kept
  build's keys (an image source's reference is in its module's JSON; SDKs and runtimes are
  tools, by digest) and the image's record need no change. Only the build cache's key needed
  one: the recipe's bytes don't change when the engine does, so the pins are hashed after
  them, and only when there are any, so that every other recipe's key is as it was.
- **An app built alone builds what it uses without installing it**, as Cargo builds a
  member's path dependencies. That's also why `update` needs no change.
- **Looking for the project is quiet** until it finds one that lists the recipe: a broken
  `zigsaw.json` above it that doesn't is none of its business.
- **A pin to an app of the project wins**, with a warning if it isn't the image the project
  built (when that's been built by then).
- **`--memory` and `--cpus` reach the apps built for one built alone**, and its `--clean`,
  `--rebuild` and the rest don't: they're about the app named.
- **Builds go one after another**: they take turns on `B:` anyway.

## Files

- `src/compose.zig` (new): the project (`read`, `load`, `parseList`, `memberPaths`), the
  order (`dependencies`, `order`), `pin`, `buildAll`, `buildFor` and `findFor`; unit tests
  for the list, references, the order and pinning.
- `src/builder.zig`: `Options.siblings`; `build` pins the recipe, or has its project build
  what it names; `inputHash` takes the pins.
- `src/deps.zig`: `checkPinned`, for the check before a project builds.
- `src/main.zig`: `build` builds a project's apps; the usage.
- `tests/build.sh`: section `apps` (base group).
- README, `docs/recipes.md`, `docs/testing.md`; 0.100.0 in `build.zig.zon` and
  `zigsaw.json`.

## Results

| what | result |
|---|---|
| unit tests | 256 pass, 4 new in `src/compose.zig` |
| `tests/build.sh`, section `apps` | 18 rows of its own (21 ok alone, with the suite's closing checks), 13-14 s |
| `tests/build.sh`, base group | 131 ok, 0 failed, twice (iteration 99's 113, every one of them, and `apps`' 18), 73-75 s |
| `tests/self.sh` | 20 ok: zigsaw's own `zigsaw.json`, which now passes the project check first, still builds the same bytes (11 min) |
| by hand | `ps` and `stop` during a project's build (BusyBox `sleep` in one app): the app before stayed installed, the one after wasn't built, and the next build went on at the stopped app's command |
| the package | zip `e0d54698`, 0.100.0; Defender finds nothing in its six programs |

## Not checked

- **A real project**: only BusyBox fixtures, not one built with zig, CMake or cargo.
- **A standard user**, `tests/matrix.sh`, the GUI suites, and `build.sh`'s other groups.

## Not this time

- `zigsaw up`/`down`: running a project's apps together, run options in the project file,
  and the `run --detach` that needs.
- Recipes in the project file itself, options per app (not installing an SDK of the
  project's, say), choosing apps with an option rather than by directory, and building apps
  that don't use each other at once (`B:` is one per session).
- A note for an app built alone names what it uses indirectly as if it used it ("A uses C").

## Yours to do

- Commit and push (`src/compose.zig` and this file are new). I read the Reproduce run,
  `build (base)` first.
- The tag `v0.100.0` is yours; I read the Release run after it.
