# zigsaw's JSON output

Commands take `--format=json` (or `--format json`). They then print one JSON value on
stdout in place of their text, for scripts: what's there, for those that read, and what
they did, for [those that change something](#commands-that-change-something).
`--format=text`, the default, is their text. Since zigsaw 0.107 for those that read, and
0.108 for the rest.

| Command | Prints |
|---|---|
| [`list`](#list) | an array: the installed apps |
| [`info <app-id>`](#info) | an object: an installed app |
| [`remote-info [<remote>] <image>`](#remote-info) | an object: an app in a remote |
| [`remote-info --show-files [<remote>] <image>`](#remote-info---show-files) | an array: its layers and their files |
| [`search [<words>...]`, `remote-ls [<remote>]`](#search-and-remote-ls) | an array: apps in the remotes' catalogs |
| [`remotes`](#remotes) | an object: the remotes, and who signs zigsaw's releases |
| [`ps [--processes] [<app-id>\|<run>...]`](#ps) | an array: the runs, builds and execs going |
| [`mask`](#mask) | an array: the masked apps |
| [`update --check [<app-id>...]`](#update---check) | an object: what's waiting, and what couldn't be checked |
| [`updates`, `updates check`](#updates) | an object: what the last check found |
| [`permissions [<app-id>]`](#permissions) | an object: what zigsaw changed outside its stores |
| [`volume ls`](#volume-ls) | an array: the volumes |
| [`volume inspect <name>`](#volume-inspect) | an object: a volume |
| [`doctor [--offline] [<app-id>]`](#doctor) | an object: the report |
| [`version`](#version) | an object: zigsaw's version |

What prints something else on stdout refuses `--format=json`, saying why: `logs`, `up`
without `-d` (the apps' logs), `remote-info --file=` (the file), `volume export` to `-`
(the archive), `build-sign --print-payload` (the payload), and `updates check --notify`
(for zigsaw-notify) and `--quiet` (nothing). `run` and `enter` take it among their own
options, before the app or the run, and only with `-d`: without, what they print is the
app's. After the app, `--format` is the app's.

```bash
zigsaw list --format=json | jq -r '.[] | select(.id == "org.nodejs.node") | .version'
zigsaw ps --format=json | jq '.[] | {run, id, memory}'
zigsaw update --check --format=json | jq -r '.waiting[] | "\(.id) \(.from) -> \(.to)"'
```

## What to rely on

- **One value, then a newline.** An array for a listing, an object for the rest, indented
  by two spaces.
- **Every key is there**, null when there's nothing to say: an app without a summary has
  `"summary": null`. Two values keep the shape of the file they come from and leave out
  what's empty: `override` (an app's saved overrides, as `overrides\<id>.json` has them)
  and `permissions` (as the image's config has them).
- **Keys are snake_case.** Sizes are integers in bytes. Times are RFC 3339 in UTC, such
  as `"2026-11-21T02:32:03Z"`. Processor time is an integer in milliseconds. Digests are
  whole, `sha256:` and 64 hex digits; the text shortens them.
- **Exit codes and stderr are the text's.** An error is `error: ...` on stderr, with
  nothing on stdout, and the exit code is 1. Hints and warnings stay on stderr. Where the
  text says on stderr that there's nothing to list ("nothing is running"), JSON prints
  `[]` and says nothing. `search` still exits 1 when nothing matches, with `[]`.
- **Later versions add keys; they don't rename or remove them.** A release that has to
  do either says so in its notes. Read the keys you use, and let the others be.
- **Strings are what the text says**, unless named here: an id, a version, a path (with
  `\`), a command line.

## list

An array, an object for each installed app, in id order.

| Key | |
|---|---|
| `id`, `version` | the app's |
| `manifest` | its image's manifest digest |
| `source` | where it came from: an image reference, or a recipe's path; null for an app installed before zigsaw recorded it |
| `commands` | its commands on your PATH: those it exports, and those its runs installed |
| `runtimes` | `[{id, version, image}]`, `image` being the runtime's manifest digest |
| `extension_points` | `[{name, version}]` |
| `extends` | `{point, version, needs}`, if it's an extension |
| `shortcuts` | the names of its Start menu shortcuts |
| `opens` | the kinds of file it's the program for, by extension |
| `registry` | the keys under HKEY_CURRENT_USER it keeps with its data |
| `override` | its saved overrides (see above), or null |
| `lazy` | `{phase, percent, error}` while a lazy install's layers download: `phase` is `fetching`, `downloading`, `paused` or `unpacking`; `percent` while downloading or paused; `error` why it paused |
| `masked` | whether updates leave it alone |
| `previous` | `{version, manifest, with_data}`: the version `rollback` goes back to, and whether its data is kept too |
| `skips` | `{version, manifest}`: the version a rollback left, which updates pass over |

## info

An object: what `remote-info` says of an image (below), less `image`, `index`,
`signature`, `download` and `installed`, and with these keys:

| Key | |
|---|---|
| `source` | as in `list` |
| `remote` | the name of the remote `source` is in, if it's in one |
| `manifest` | the installed image's manifest digest |
| `location` | where its files are |
| `data` | its data directory: its own volume |
| `masked`, `previous` | as in `list` |

## remote-info

An object, without installing anything:

| Key | |
|---|---|
| `id`, `version` | the app's |
| `name`, `summary`, `homepage`, `license` | as its recipe gives them |
| `image` | the image, as zigsaw resolved it |
| `manifest` | its manifest digest |
| `index` | the digest of the multi-platform index it was picked from, for windows/amd64 |
| `signature` | `{state, by, why}`: `state` is `signed` (`by` whom), `missing`, `no_key` (no key here for its registry, so not checked) or `wrong` (`why`; `install` refuses it) |
| `download` | `{bytes, missing}`: what installing it downloads, its config and layers, and how much of the layers' bytes the store hasn't got |
| `runtimes` | `[{id, version, image}]` |
| `layer_format` | its own layer's: `tar`, `gzip` or `estargz` |
| `extension_points`, `extends` | as in `list` |
| `commands` | the commands it exports |
| `shortcuts` | the names of its shortcuts |
| `opens` | kinds of file by extension (`".rnote"`), and URL schemes (`"vscodium:"`) |
| `unsupported` | `[{sandbox, why, runtime}]`: a sandbox it can't work under, and why; `runtime` names the runtime that can't, or is null for the app's own reason |
| `permissions` | as its config has them: `sandbox`, `network`, `hosts`, `devices`, `filesystem`, `services`, `uses`, `unsupported`, `commands`, `host` |
| `uses` | `[{name, port}]`: the ports it connects to, its own and its runtimes' |
| `registry` | as in `list` |
| `build` | as its config says: `{sdk, sources, vendor, images, network, host}`; null for an image made before iteration 4 |
| `installed` | `{version, manifest}` of the installed app of that id, or null |

## remote-info --show-files

An array, an object for each of the image's layers: the app's own first, then its
runtimes'.

| Key | |
|---|---|
| `id`, `version` | the app or runtime whose layer it is |
| `layer` | its digest |
| `format` | `tar`, `gzip` or `estargz` |
| `files` | `[{name, size}]` by name, `name` with `/`; null for a layer whose format can't be listed without downloading it. An image with only such a layer fails, as in text |

## search and remote-ls

An array of the catalogs' entries, in the text's order: the best matches first, then by
id.

| Key | |
|---|---|
| `remote` | the remote whose catalog it's in |
| `id`, `version`, `manifest` | the app's, at the tag the catalog lists |
| `download` | what installing it downloads, in bytes, its runtimes' layers included |
| `name`, `summary`, `homepage`, `license` | as its recipe gives them |
| `commands` | the commands it exports |
| `shortcuts`, `associations` | objects: each shortcut's description by its name, and each kind of file's by extension |
| `permissions` | as its config has them |
| `registry` | as in `list` |
| `runtimes` | `"<id> <version>"` for each |

## remotes

An object:

| Key | |
|---|---|
| `remotes` | `[{name, url, default, from_env, signers, login}]`, in order: `default` for the first, where an app named by id alone comes from; `from_env` when `ZIGSAW_REGISTRY` moved it, for this command |
| `signers` | `[{kind, key, identity, issuer, built_in}]`: whose signatures count for the remote's images. `kind` is `key` (with its `key` fingerprint) or `keyless` (with the `identity` a certificate must name and its `issuer`); `built_in` when zigsaw comes with it |
| `login` | `{kind, username, helper}`, or null without one: `kind` is `credential_manager` (with the `username`), `environment`, `docker_config` or `docker_helper` (with the `helper`'s name) |
| `releases` | `{signers}`: whose signatures count for zigsaw's own releases |

## ps

An array, an object for each run, build and exec going, as `ps` filters them.

| Key | |
|---|---|
| `run` | its zigsaw's PID: what `kill`, `enter` and `logs` take |
| `kind` | `run`, `build` or `exec` (a command `zigsaw enter` started) |
| `id`, `version`, `manifest` | the app's, or the recipe's (`version` and `manifest` null while a build hasn't got them) |
| `sandbox` | `soft`, `low` or `appcontainer`; a build's is `appcontainer` while a command runs in its container, else null |
| `network` | `all`, `none` or `list` |
| `inside` | the run it's inside, by its zigsaw's PID: one started from another, as `--share=commands` does, or an exec's run |
| `started` | when |
| `process_count`, `memory`, `cpu_ms` | its processes now, the memory they've committed, and the processor time of all it started; null when its job can't be looked into |
| `memory_limit`, `cpus` | `--memory` in bytes and `--cpus`, if given |
| `ephemeral` | whether its data is thrown away after |
| `command` | the whole command line it started; a build's command |
| `shortcut` | the shortcut it was started from |
| `log` | a detached run's log |
| `project` | the zigsaw.json whose `up` started it |
| `ports` | `"<service>=<port>"` for each service it serves |
| `module`, `step`, `n`, `of` | a build's module, `build` or `vendor`, and which command of how many |
| `processes` | with `--processes`: `[{pid, ppid, name, command_line, memory, cpu_ms, started, run}]`, its processes, each naming its parent; `run` is set on the zigsaw of a run inside it, whose processes are that run's. Null without `--processes` |

## mask

An array: `[{id, version}]`, the installed apps updates leave alone.

## update --check

An object:

| Key | |
|---|---|
| `waiting` | `[{id, from, to, from_manifest, to_manifest, adds}]`: the apps a new image waits for. `adds` is what the new one may reach that the installed one may not, `{permissions, uses, registry}`, or null if nothing |
| `failed` | the ids of the apps that couldn't be checked (stderr says why); the exit code is 1 if there are some |

## updates

`updates` and `updates check` print an object:

| Key | |
|---|---|
| `checked` | when the last check was; null if none was |
| `waiting` | as for `update --check`; `adds` is null in what a zigsaw before 0.107 found |
| `failed` | the apps the last check couldn't check |
| `zigsaw` | `{latest, this}`, if a newer zigsaw is out |
| `zigsaw_failed` | whether the last check couldn't find out zigsaw's latest version |
| `daily_check` | whether a daily check is on |

As in text, `updates` takes what it shows as seen.

## permissions

An object:

| Key | |
|---|---|
| `store` | `{root, apps}`: this store, and `[{id, grants}]` for each app with changes |
| `grants` | `[{kind, path, lasts}]`: `kind` is `low` (a low label on `path`), `appcontainer` (its container may use `path`) or `loopback` (exempt from loopback isolation; `path` null). `lasts` is `run` (until its last run ends, or `zigsaw repair`), `working_directory` (while it has cwd) or `permissions` (while its permissions name the path) |
| `other_stores`, `deleted_stores` | `[{store, id, kind, path}]`: other stores' changes, and those of stores since deleted, which `zigsaw repair` takes back |
| `unexplained` | your folders labelled low that no record explains |
| `daily_checks` | `[{name, store, gone}]`: the scheduled tasks of the daily checks, `gone` when their store is |

With an app's id, only its changes; `unexplained` and `daily_checks` are then empty.

## volume ls

An array, an object for each volume: `{name, path, external, own, mounts}`.
`external` is whether it's kept outside the store, and `own` whether it's an app's data.
`mounts` is `[{app, target, read_only}]`: `app` null for the store-wide overrides, which
mount it for every app, and `target` `"."` where it's all of the app's data.

## volume inspect

An object: what `volume ls` says of it, with `exists` (whether its folder is there),
`bytes` and `files` (null when it isn't), `in_use` (whether a run uses it) and `grants`
(`[{app, kind}]`, what apps' runs were given on its folder).

## doctor

An object:

| Key | |
|---|---|
| `version` | this zigsaw's |
| `sections` | `[{title, findings}]`, in the report's order |
| `findings` | `[{level, text, fix}]`: `level` is `ok`, `note`, `warning` or `problem`; `fix` says what puts it right, lines joined by newlines, or is null |
| `problems`, `warnings` | how many; the exit code is 1 if there are problems |

The text comes out section by section, as it's found; JSON comes out once it's all found.

## version

An object: `{version}`.

## Commands that change something

Since 0.108. What they print is what they did, **once they're done**: one value, as for
the rest. What they say as they go (notes, questions, warnings) stays on stderr, as in
text, and their questions are asked as in text, so `--yes` and the like answer them.

- **A command that stops at a failure prints nothing**, as the others do: `install`,
  `build`, `rollback`, `volume rm`... What it did before the failure, such as the apps a
  project's `build` installed before one failed, stderr says.
- **One that goes on past failures prints what it did, with what failed**, and exits 1:
  `update` (`failed`), `repair` (`failed`, `grants_unsettled`), and `kill` and `down`
  (an `outcome` of `cant`).
- **Nothing but the JSON is on stdout.** A build's tools, and the zigsaw `upgrade`
  starts, write theirs on stderr.
- Where what a command did is an installed app, it's the app's [`list`](#list) object,
  with more keys.

| Command | Prints |
|---|---|
| [`install`](#install) | an object: the app |
| [`build`](#build) | an array: the apps it built and installed |
| [`update`](#update) | an object: what it updated, left alone, and couldn't |
| [`rollback`](#rollback) | an object: from and to, and the data |
| [`uninstall <app-id>`](#uninstall) | an object: what it removed |
| [`uninstall --unused`](#uninstall---unused) | an object: what it removed, or would, and kept |
| [`upgrade`](#upgrade) | an object: zigsaw's versions |
| [`mask <app-id>...`, `mask --remove`](#mask-with-apps) | an array: each app |
| [`override`](#override) | its saved overrides, or null |
| [`run -d`, `enter -d`](#run--d-and-enter--d) | an object: the run or exec |
| [`kill`, `down`](#kill-and-down) | an array: each run, build or exec ended |
| [`up -d`](#up--d) | an array: each app |
| [`volume create`, `rm`, `prune`](#volume-create-rm-and-prune) | the volume; an array; an object |
| [`volume export`, `import`](#volume-export-and-import) | an object: what went into or out of the archive |
| [`remote-add`, `remote-modify`, `remote-delete`](#remote-add-remote-modify-and-remote-delete) | an object: the remote |
| [`build-export`, `build-update-repo`, `build-sign`](#build-export-build-update-repo-and-build-sign) | an object: what went to the registry |
| [`repair`, `permission-remove`, `updates on` and `off`](#repair-permission-remove-updates-on-and-off) | an object |

### install

The app's [`list`](#list) object, with:

| Key | |
|---|---|
| `replaced` | `{version, manifest}`: the version it replaced, which `rollback` goes back to; null for a first install, or the same image again |
| `old_kept_running` | whether that version's files stay, as a run of it goes on |

### build

An array: for each app it built and installed, in the order it did (one for a recipe,
each of a project's `"apps"`), what [`install`](#install) prints, and `reused`: whether
the store had it built from the same inputs, so nothing was built.

### update

An object, without `--check` (with it, see [above](#update---check)):

| Key | |
|---|---|
| `updated` | `[{id, from, to, from_manifest, to_manifest}]` |
| `up_to_date` | the ids of the apps that were |
| `skipped` | `[{id, why}]`: `why` is `masked`, `no_source` (it doesn't record where it came from), `pinned` (installed by digest) or `skips` (the new version is the one a rollback left) |
| `failed` | the ids of the apps that couldn't be updated, as stderr says; exit 1 if there are some |

### rollback

An object: `{id, from, to, from_manifest, to_manifest, data, snapshot}`. `data` is
`taken` (its data went back too), `kept` (it stays, and the copy is kept), `none` (no
copy was kept) or `only` (`--data-only`; `from` and `to` are then the same).
`snapshot` is `{bytes, files, taken}`, the copy that went back or is kept, or null.

### uninstall

An object: `{id, version, manifest, data_deleted, data, kept_volumes, files_kept,
removed}`. `data` is where its data stays, null with `--delete-data`; `kept_volumes` the
volumes it mounted, which stay; `files_kept` whether its files stay until
`uninstall --unused`, as a run uses them; `removed` `{commands, shortcuts,
associations}`.

### uninstall --unused

An object: `{dry_run, freed, removed, kept, forgot_previous}`. `freed` is in bytes, or
what would be, with `--dry-run`.

| Key | |
|---|---|
| `removed` | `{blobs, deployments, tmp, downloads, tool_caches, work, volumes, kept_data}`, each `{count, bytes}`, but `volumes`, `[{name, bytes}]`. Null for what wasn't asked for: `downloads`, `tool_caches` and `work` without `--downloads`, `volumes` without `--volumes` |
| `kept` | `{deployments_in_use, ephemeral, downloads, tool_caches, work, build_images, previous, previous_data, volumes}`: counts of what runs use; `{count, bytes}` of what stays (null where it went); `build_images` a count; `volumes` the names of those nothing mounts, or that runs use |
| `forgot_previous` | how many previous versions `--previous` forgot |

### upgrade

An object: `{from, to, latest, upgraded}`. Up to date, `to` is `from` and `upgraded` false.

### mask with apps

`mask <app-id>...` and `mask --remove <app-id>...`: an array, `[{id, version, masked,
changed}]`, `changed` false where it was so already. `mask` alone lists, as
[above](#mask).

### override

What's saved for the app after the change, in the shape of `list`'s `override`, or null
for nothing; the same without options, or with `--show`. With `--global`, the store-wide
ones.

### run -d and enter -d

`run -d`: `{run, id, log, in_job}`. `run` is its number, as `ps`, `kill` and `logs`
take it; `log` its log; `in_job` whether the job this zigsaw is in kept it, so it ends
when that job does.

`enter -d`: `{run, inside, id, command, in_job}`. `run` is the exec's number, as `ps`
lists it, `inside` the run's.

### kill and down

An array: `[{run, id, kind, inside, outcome, why}]`, for each run, build and exec it
ended or tried to, in `ps`'s order, those inside what was named too. `outcome` is
`stopped` (it stopped when asked), `ended` (with `--now`, it had ended by then), `gone`
(it had ended before), `killed`, `cleaning` (killed, its zigsaw still cleaning up) or
`cant` (`why` says why; exit 1). `down` with nothing of the project running prints `[]`.

### up -d

An array: `[{id, run, log, ports, state}]`, `state` being `started`, `restarted` (its
run had another image or entry) or `up_already`. Without `-d`, `up` prints the logs, and
refuses `--format=json`.

### volume create, rm and prune

`volume create`: the volume, as [`volume ls`](#volume-ls) has it. `volume rm`:
`[{name, files_kept}]`, `files_kept` being where a volume kept elsewhere leaves its
files, or null. Since 0.108, `rm` checks every name before it removes any, in text too.
`volume prune`: `{dry_run, removed, in_use, bytes}`, `removed` `[{name, bytes}]` and
`in_use` the names of those kept as a run uses them.

### volume export and import

`volume export`: `{volume, file, gzip, bytes, files, links_passed_over, archive_bytes,
left_out}`, `left_out` what an app's own volume leaves out without `--all`.
`volume import`: `{volume, file, bytes, files, links_passed_over, made, replaced,
exported}`. `file` is null for `-`; `made` whether the import made the volume;
`replaced` how many files and folders it had; `exported` `{volume, version, at}` as the
archive says, or null for one zigsaw didn't make.

### remote-add, remote-modify and remote-delete

`remote-add` and `remote-modify`: the remote, as [`remotes`](#remotes) has it, and
`changed` (false for `--if-not-exists` on one that's there). `remote-delete`: `{name,
url, signers_removed, login_kept, remotes_left}`, `login_kept` when a login saved for its
registry stays, which no remote is for now.

### build-export, build-update-repo and build-sign

`build-export`: `{id, version, image, manifest, sources}`. `image` is where it went, by
its tag; `sources` with `--sources`: `{tag, files, missing}`, `tag` null if none went.
`build-update-repo`: `{catalog, registry, apps}`, `apps` `[{id, version, manifest}]`.
`build-sign` and its `--bundle`: `{image, digest, tag, by, already}`, `by` who signed a
keyless bundle (null for a key's), `already` when that signature was there, so nothing
was pushed. `build-sign --check`: `{image, manifest, signed_by}`; not signed, it fails.

### repair, permission-remove, updates on and off

`repair`: `{apps, failed, grants_unsettled}`. `permission-remove`: `{path, outcome}`,
`outcome` being `removed`, `no_label` (the path has no label of its own) or `not_low`.
`updates on` and `off`: `{daily_check}`, whether it's on now.
