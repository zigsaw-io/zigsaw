# Zigsaw

Image-based container solution for running sandboxed program on Windows.

Think Flatpak for Windows programs: apps are built from pinned sources into
OCI-style images, installed per user, and run in a clean environment with their
own data directory. No admin rights, no Hyper-V; it works on Windows Home.

Status: [iteration 1](docs/iteration-1.md) is complete. Zigsaw builds,
installs, runs, shares through registries, and exposes the commands of
command-line apps. Git, Node, Python and the zig toolchain are tested.

## Quick start

Requires Zig 0.16.

```powershell
zig build
.\zig-out\bin\zigsaw.exe build recipes\node.json
.\zig-out\bin\zigsaw.exe run org.nodejs.node -e "console.log(process.version)"
```

Installing an app also puts its commands (here `node`, `npm` and `npx`) in
`%LOCALAPPDATA%\zigsaw\bin`. Add that directory to your PATH, and they run
through zigsaw by name:

```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\zigsaw\bin", 'User')
```

PATH is searched in order, so if another copy of a command comes earlier (say
an installed Node), that one wins. `where node` shows which is found first.

## Commands

```
zigsaw build <recipe.json>             build an app from a recipe, install it and its commands
zigsaw pull <image>                    install an app and its commands from a registry
zigsaw push <app-id> <image>           publish an installed app to a registry
zigsaw run [options] <app-id> [args]   run an installed app
zigsaw list                            list installed apps and their commands
zigsaw rm [--delete-data] <app-id>     uninstall an app and its commands
```

## Sharing apps through registries

zigsaw images are standard OCI images, so any OCI registry can hold them:
ghcr.io, Docker Hub, a self-hosted zot or distribution. An image is named
`<registry>/<repository>[:tag][@digest]`:

```powershell
zigsaw push org.nodejs.node ghcr.io/you/node          # tagged 24.21.0, the app's version
zigsaw pull ghcr.io/you/node:24.21.0                  # on another machine
zigsaw pull ghcr.io/you/node@sha256:7b9280e4...       # exactly this build
```

The manifest travels byte for byte, so an image has the same digest in every
store and registry. `pull` downloads only blobs the store doesn't have, checks
each one against its digest, and refuses images that aren't zigsaw apps
(such as Docker container images). Like `build`, it shows what the app is
allowed to reach before you run it.

Anonymous pulls of public images work without setup. Pushing, and pulling
private images, needs credentials in `ZIGSAW_REGISTRY_USERNAME` and
`ZIGSAW_REGISTRY_PASSWORD`. For ghcr.io, that's your GitHub user name and a
token with the `write:packages` scope. Registries on `localhost` are reached
over plain HTTP; all others over HTTPS.

`run` options go before the app id, as with `flatpak run`:

| Option | Effect |
|---|---|
| `--command=<name>` | Run one of the app's exported commands, or another executable from the app or System32 (e.g. `--command=cmd`) |
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

`exports` names the commands an app puts on PATH. Without it, the app exports
its command under its file name (`busybox` above); `"exports": {}` exports
nothing. An export can pass arguments before the caller's, with `${app}` for
the app's directory. That's how Node's recipe runs npm without its `.cmd`
wrapper:

```json
"exports": {
  "node": { "command": "node.exe" },
  "npm": { "command": "node.exe", "args": ["${app}\\node_modules\\npm\\bin\\npm-cli.js"] }
}
```

If another installed app already exports a name, the build skips it with a
warning.

## How it works

**Images** are standard OCI image manifests with a zigsaw config
(`application/vnd.zigsaw.app.config.v1+json`) and plain, deterministic tar
layers, so any OCI registry can store them.

**Builds** never unpack sources to disk. zigsaw indexes the files each source
contributes and streams them from the downloads and zip archives straight
into the layer, hashing it on the way. The app's files are created once, when
the layer is deployed, by several workers in parallel. Rebuilding an
installed app creates no files at all. Creating files is the slow part on
Windows, because Defender scans each new one.

**Store** (`%LOCALAPPDATA%\zigsaw`, or `%ZIGSAW_HOME%`):

```
blobs\sha256\<hex>     manifests, configs, layers
refs\<id>.json         installed app -> manifest digest
deploy\<hex>\          unpacked app tree, shared by all runs
data\<id>\             per-app writable state, kept across runs
grants\<id>.txt        host paths granted to the app's AppContainer
bin\<name>.exe         command shims, with a <name>.shim file saying what each runs
cache\downloads\<hex>  fetched sources, by sha256
```

**Command shims** are copies of the small `zigsaw-shim.exe` that is installed
next to `zigsaw.exe`. A shim reads its `.shim` file and runs
`zigsaw run --command=<name> <app>` with the caller's arguments exactly as
typed, and exits with the app's exit code. Shims are real executables rather
than `.cmd` scripts, so programs that start `node` or `git` directly find
them, and Ctrl+C doesn't ask "Terminate batch job?".

**Runs** get an environment built from scratch: `PATH` is the app's
directories plus System32. `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `TEMP`
point into `data\<id>\home`. The working directory is that home folder unless
the app has the `cwd` filesystem permission. A job object ends the whole
process tree when the run ends. Deployed app files deny writes and deletes to
the user, so no run, and nothing else running as you, can change an installed
app.

**`--sandbox=appcontainer`** also runs the app under a per-app AppContainer
identity (`zigsaw.<id>`). It can then read and write only its data directory,
read its own app files, and use the host paths and network it was granted.
Host grants are ACL entries on those paths; `zigsaw rm` removes them again.
It suits self-contained tools such as busybox and ripgrep. Git, Node scripts,
npm and zig fail under it, because Windows doesn't let AppContainers resolve
real paths; see [the iteration 1 findings](docs/findings-iteration-1.md).

## Testing

```bash
zig build test          # unit tests
bash tests/matrix.sh    # runs real tools through both sandboxes (Git Bash, network)
bash tests/shims.sh     # command shims end to end
bash tests/registry.sh  # push and pull through a local registry (see the script's header)
```

The scripts build the recipes they need from [recipes/](recipes/) into
temporary stores unless `ZIGSAW_HOME` points at one. The matrix reports every
check whose result differs from zigsaw's intended behaviour. The registry
tests need a local registry such as [zot](https://zotregistry.dev) on
`localhost:5000`.

## Known gaps

- Batch files (`.cmd`/`.bat`) can't be the command yet; run them through
  `--command=cmd <app> /c ...`, or export the program they wrap, as Node's
  recipe does for npm.
- Global package installs, like `npm install -g`, fail, because they write into
  the read-only app directory.
- Shims can't pass zigsaw options such as `--sandbox`; they always run the
  app's defaults.
- Apps that locate folders with `SHGetKnownFolderPath` instead of environment
  variables would bypass the data-directory redirect. None of the tested tools
  do.
- Installing an app with many files is limited by Defender scanning each new
  file: about 16 s for zig's 19.5k files, 3 s for Node.
- The registry isn't isolated.
- Old blobs are never garbage-collected, and a crashed build can leave files
  in `tmp\`.
- Registry credentials come only from environment variables, and
  multi-platform image indexes aren't supported.

[docs/iteration-1.md](docs/iteration-1.md) lists what hasn't been tested yet.
