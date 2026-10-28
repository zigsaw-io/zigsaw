# How it works

**Images** are standard OCI image manifests with a zigsaw config
(`application/vnd.zigsaw.app.config.v2+json`) and deterministic tar layers,
gzip-compressed (`application/vnd.oci.image.layer.v1.tar+gzip`), so any OCI
registry can store them. The layers are those of the app's runtimes, in the
order the config lists them, then one of the app's own files. The config also
records how the image was built: the hash of every source, and any SDK
images. zigsaw still reads the plain tar layers of images made before
iteration 7, and the v1 configs of images made before runtimes existed;
older versions of zigsaw refuse v2 images, and gzip layers.

**Builds** without build commands never unpack sources to disk. zigsaw
indexes the files each source contributes and streams them from the
downloads and archives straight into the layer, compressing and hashing it on
the way. Compressed source tars are decompressed once, into the download
cache. The app's files are created once, when the layer is deployed (a gzip
layer is decompressed first, to a temporary tar), by several workers in
parallel. Rebuilding such an app creates no files at all. Creating files is
the slow part on Windows, because Defender scans each new one. Builds with
build commands need real files, so they unpack their sources into a directory
under `tmp\`, mapped to `B:`, and make the layer from what ends up in
`B:\prefix`.

**Store** (`%LOCALAPPDATA%\zigsaw`, or `%ZIGSAW_HOME%`):

```
blobs\sha256\<hex>     manifests, configs, layers
refs\<id>.json         installed app -> manifest digest
deploy\<hex>\          an unpacked layer, by layer digest, shared by all runs and apps
data\<id>\             per-app writable state, kept across runs
grants\<id>.txt        host paths granted to the app's AppContainer, or labelled low for its runs
grants\<id>.cwd        those of them that were a run's working directory
overrides\<id>.json    run options saved with `zigsaw override`
bin\<name>.exe         command shims, with a <name>.shim file saying what each runs
aliases\<id>\          shims for the aliases an app's runs have: its own and its runtimes'
certs\roots-<hex>.pem  Windows' trusted roots, for runs whose images name ${roots}
cache\downloads\<hex>  fetched sources, by sha256 (and decompressed tars)
cache\images\<hex>     marks images that builds use as runtimes or SDKs, kept like downloads
cache\builds\<hex>     the image of an earlier build, by a hash of its inputs
cache\tools\<id>\      the cache of a build tool whose image uses ${cache}
cache\work\<key>\       a project's modules' work directories, kept between its builds
tmp\                   staging area, and the data of --ephemeral runs
lock, *.lock           lock files that let zigsaw commands run side by side
```

**Command shims** are copies of the small `zigsaw-shim.exe` that is installed
next to `zigsaw.exe`. A shim reads its `.shim` file and runs
`zigsaw run --command=<name> <app>` with the caller's arguments exactly as
typed, and exits with the app's exit code. Shims are real executables rather
than `.cmd` scripts, so programs that start `node` or `git` directly find
them, and Ctrl+C doesn't ask "Terminate batch job?". Commands that are GUI
programs get `zigsaw-shimw.exe` instead, the same program built as a GUI
one, which starts zigsaw without a console (`DETACHED_PROCESS`); zigsaw
reads the subsystem from the executable's PE header when it writes the
shim. Start menu shortcuts are `.lnk` files that
run these shims. A shim that a shortcut started says so (Windows puts the
shortcut's path in its `STARTUPINFO`, with `STARTF_TITLEISLINKNAME`), and
zigsaw starts the app with the same.

**File associations** are keys in `HKCU\Software\Classes`: one of zigsaw's
per app and extension, with the command, and its name in the extension's
`OpenWithProgids`. The command is a copy of the same shim in
`open\<app id>\`, whose `.shim` file says its arguments are files: it runs
`zigsaw run --command=<name> --file=<argument> <app>`. `--file` adds the
file to the run's grants as if it were a directory: a low integrity label
or an entry for the app's capability, on that file alone.

**Runs** get an environment built from scratch: `PATH` is the app's
directories, then its runtimes', then System32. `USERPROFILE`, `APPDATA`,
`LOCALAPPDATA` and `TEMP` point into `data\<id>\home`, and the user's folders
the app may use are directory junctions there, to the real ones. Windows
follows a junction as a path, and grants or denies access by what it
points to; deleting a tree or changing its ACL (inheritance) stops at the
junction. The working directory
is that home folder unless the app has the `cwd` filesystem permission. A job
object ends the whole process tree when the run ends. Deployed files deny
writes and deletes to the user, so no run, and nothing else running as you,
can change an installed app or runtime.

The app shares the terminal, so Ctrl+C and Ctrl+Break reach it just as when
it runs alone, also through a shim. zigsaw waits for it and passes on its
exit code. Closing the terminal gives the app the usual time to clean up.
Whatever the app leaves running then ends with the run, even processes it
started detached.

**`--sandbox=low`** runs the app at low integrity, with a copy of your token
that Windows lets any program make of its own. The app can then write only
where the integrity label is low: zigsaw labels its data directory, and the
host paths it may write (`cwd`, your folders and `--filesystem` paths without
`:ro`). It
can still read whatever you can, and use the network. Every tool the matrix
runs works this way, including git, npm and zig builds.

- A label lasts as long as [grants do](#how-long-grants-last), and is
  inherited by everything below the path. Meanwhile any low-integrity
  program can write there, not only the app. Taking a label back keeps the
  labels other apps' runs need, and labels zigsaw didn't make.
- zigsaw won't label a drive's root, your user profile, or a directory your
  profile is in; grant a directory inside it, or read-only access.
- The first label of a large tree takes a while, as Windows labels every
  file below it: about 2 s for 20,000 files.

**`--sandbox=appcontainer`** also runs the app under a per-app AppContainer
identity (`zigsaw.<id>`). It can then read and write only its data directory,
read its own files and its runtimes', and use the host paths and network it
was granted.
Grants are ACL entries for a capability of the app's own, which only its runs
hold; those on host paths go as [grants do](#how-long-grants-last). (An entry for the
AppContainer's own SID, as zigsaw made before, would keep low-integrity
programs out of the files: see [findings](findings.md).)
Windows gives an AppContainer a temporary directory of its own, under
`LOCALAPPDATA`, so zigsaw makes that one in the data directory too.
It suits self-contained tools such as busybox, ripgrep, bat, fzf, zot and
zstd. What else works depends on the version of Windows, as it decides what
AppContainers may do:

- **Windows 11 26300.9550** lets them resolve real paths, so Python, zig,
  CMake and Go builds work too. It doesn't let them see directories that
  grant them nothing, such as the drive root. Git's and Node's recipes set
  variables that keep them from looking there where they can: git's
  configuration, `ls-remote`, Node scripts and `npm install` work, but
  `git init`/`commit`, `npm install -g` and Node's `fs.realpathSync` don't.
- **Older builds of Windows 11** didn't let them resolve real paths, which
  git, Node, zig and CMake need.
- **Windows Server 2025** doesn't let them open `NUL`, so git doesn't start
  at all, and Go builds fail.

See [findings](findings.md). `tests/matrix.sh` checks what the Windows
it runs on allows, and prints it.

## How long grants last

What a run is granted on host paths, low labels and ACL entries, stays only
while a run of the app with nothing on its command line would be granted it
again:

- under the sandbox its overrides choose (`soft` grants nothing);
- for the paths and folders its permissions and overrides name;
- for each working directory such runs had, while it keeps `cwd`, so that a
  big project isn't granted again on every run.

What a command line adds, with `--file`, `--filesystem` or `--sandbox`, is
taken back when the app's last run ends: one run that hands a file to
another, as Text Editor's does, leaves it to that one. What the app's
permissions or overrides no longer give goes as soon as `zigsaw override` or
an update takes it away, unless a run of the app is going, and then when the
last one ends. `zigsaw rm` takes back everything, and `zigsaw repair` what
an earlier zigsaw kept until `rm`. A run that didn't end (zigsaw was killed)
leaves its grants until the app's next run ends.

So to keep a folder granted, save the sandbox too: `zigsaw override
--sandbox=low <app>`. A sandbox given only on the command line grants the
app's folders afresh on each run, and takes them back after, which takes a
while for a big folder.
