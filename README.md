# Zigsaw

Image-based container solution for running sandboxed program on Windows.

Think Flatpak for Windows programs: apps are built from pinned sources into
OCI-style images, installed per user, and run in a clean environment with their
own data directory. No admin rights, no Hyper-V; it works on Windows Home.

## Quick start

Requires Zig 0.16.

```powershell
zig build
.\zig-out\bin\zigsaw.exe build recipes\busybox.json
.\zig-out\bin\zigsaw.exe run net.frippery.busybox ls -la
```

## Commands

```
zigsaw build <recipe.json>             build an app from a recipe and install it
zigsaw run [options] <app-id> [args]   run an installed app
zigsaw list                            list installed apps
zigsaw rm [--delete-data] <app-id>     uninstall an app
```

`run` options go before the app id, as with `flatpak run`:

| Option | Effect |
|---|---|
| `--command=<exe>` | Run another executable from the app, or from System32 (e.g. `--command=cmd`) |
| `--sandbox=soft\|appcontainer` | `soft` (default) shapes the environment only; `appcontainer` also enforces permissions |
| `--filesystem=<cwd\|path>[:ro]` | Grant access to a host location |
| `--share=network` / `--unshare=network` | Override the app's network permission |
| `--env=NAME=VALUE` | Set an environment variable |
| `--ephemeral` | Use a fresh data directory, deleted after the run |
| `-v`, `--verbose` | Print the resolved command, environment and grants |

## Recipes

A recipe is a JSON file listing pinned sources and how the app runs:

```json
{
  "id": "net.frippery.busybox",
  "version": "FRP-6075-g169694ebd",
  "command": "busybox.exe",
  "path": ["."],
  "env": {},
  "permissions": { "network": false, "filesystem": [] },
  "sources": [
    {
      "url": "https://frippery.org/files/busybox/busybox-w64-FRP-6075-g169694ebd.exe",
      "sha256": "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075",
      "dest": "busybox.exe"
    }
  ]
}
```

Sources are either a `url` (a `sha256` is required; leave it out once and the
build error prints the hash to pin) or a local `path`. A source is a single
`file`, or a `zip` extracted into `dest` with optional `strip`. The type is
inferred from the file name. Building the same recipe always produces the
same image digest.

## How it works

**Images** are standard OCI image manifests with a zigsaw config
(`application/vnd.zigsaw.app.config.v1+json`) and plain, deterministic tar
layers, so any OCI registry can store them.

**Store** (`%LOCALAPPDATA%\zigsaw`, or `%ZIGSAW_HOME%`):

```
blobs\sha256\<hex>     manifests, configs, layers
refs\<id>.json         installed app -> manifest digest
deploy\<hex>\          unpacked app tree, shared by all runs
data\<id>\             per-app writable state, kept across runs
grants\<id>.txt        host paths granted to the app's AppContainer
cache\downloads\<hex>  fetched sources, by sha256
```

**Runs** get an environment built from scratch: `PATH` is the app's
directories plus System32. `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `TEMP`
point into `data\<id>\home`. The working directory is that home folder unless
the app has the `cwd` filesystem permission. A job object ends the whole
process tree when the run ends.

**`--sandbox=appcontainer`** also runs the app under a per-app AppContainer
identity (`zigsaw.<id>`). It can then read and write only its data directory,
read its own app files, and use the host paths and network it was granted.
Host grants are ACL entries on those paths; `zigsaw rm` removes them again.

## Known gaps

- Batch files (`.cmd`/`.bat`) can't be the command yet; run them through
  `--command=cmd <app> /c ...`.
- Apps that locate folders with `SHGetKnownFolderPath` instead of environment
  variables bypass the data-directory redirect.
- The registry isn't isolated.
- Old blobs are never garbage-collected.
