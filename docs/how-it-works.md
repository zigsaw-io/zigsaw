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
versions\<id>.previous.json  the version the installed one replaced, whose blobs prune keeps
versions\<id>.skip.json      the version a rollback left, which updates pass over
versions\<id>.held     there while `zigsaw hold` keeps updates away from the app
deploy\<hex>\          an unpacked layer, by layer digest, shared by all runs and apps;
                       placeholders while a lazy pull fetches it
lazy\<hex>\            a layer pulled lazily: its TOC, its download, what to copy from the
                       store's other layers, its helper's state and log
data\<id>\             per-app writable state, kept across runs
volumes\<name>\        a volume's files, which outlive the data of the apps that mount it
volumes\<name>.json    a volume kept in a folder elsewhere: where
volumes\<name>.lock    held shared by each run that mounts the volume
grants\<id>.txt        host paths granted to the app's AppContainer, or labelled low for its runs
grants\<id>.cwd        those of them that were a run's working directory
grants\<id>.mounts     where in the app's data directory zigsaw linked a volume
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

**URL schemes** are keys there too: one of zigsaw's per app and scheme, with the
command, and the same as `<scheme>` itself, if nothing else has it. The command is
a shim in `open\<app id>\urls\`, whose `.shim` file names the schemes: it takes
one argument, a URL of one of them, or refuses, and runs `zigsaw run
--command=<name> <app> <url>`, granting nothing. An app with either is listed for
Settings' Default apps, under `HKCU\Software\Zigsaw\Apps\<id>\Capabilities`, which
`HKCU\Software\RegisteredApplications` names.

**A zigsaw started from inside a run**, as a command under `--share=commands` is,
sees `ZIGSAW_ID` there, and takes your own variables back first, from
`CreateEnvironmentBlock`: what it then finds from them, such as your folders, is
yours and not the run's.

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

**Volumes** are junctions too, at the paths in `data\<id>\` that `--volume` names,
to a folder in `volumes\`, one elsewhere that `volume create --path` recorded, or
one of yours. A run makes them before it joins the app's runs, while it can tell
whether another goes on: only then may it replace a link, or move the app's own
files into an empty volume (by renaming them, and then having the volume's ACL
inherited again, as moved files keep what they inherited where they were). The
folder is then one of the run's host paths, granted, recorded and taken back as
`--filesystem`'s are: a folder in the store is one no run may otherwise write
(below), but a volume's is the apps'. `grants\<id>.mounts` lists the links made, so
that the app's last run to end, or a change to its overrides, removes those no
saved mount names any more.

The app shares the terminal, so Ctrl+C and Ctrl+Break reach it just as when
it runs alone, also through a shim. zigsaw waits for it and passes on its
exit code. Closing the terminal gives the app the usual time to clean up.
Whatever the app leaves running then ends with the run, even processes it
started detached.

Which sandbox a run gets: the one its `--sandbox` names, else the app's
overrides', else the store-wide overrides' (`override --global`), else the
one the app's image asks for (`permissions.sandbox`), else `low`.
`--sandbox=soft` enforces nothing beyond the environment above.

**`--sandbox=low`**, the default, runs the app at low integrity, with a copy
of your token that Windows lets any program make of its own. The app can then write only
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
  profile is in. A run from one of them, of an app with `cwd`, gets its
  working directory read-only, with a warning; a path granted with
  `--filesystem` there is refused: grant a directory inside it, or
  read-only access.
- Nor will it label zigsaw's store, the folder `zigsaw.exe` is in, a
  directory that holds either, or one inside them; nor will
  `--sandbox=appcontainer` let an app write there. A label there would
  reach every app's programs, and Windows starts a program whose file is
  labelled low at low integrity, whoever starts it: an app that asks for
  `soft` would run at low. A soft run of a program labelled low says so.
- A program a run writes (`.exe`, `.com`, `.scr`) comes out labelled low:
  it inherits the label of the folder, or a low-integrity process wrote it,
  as an AppContainer's are. zigsaw watches the folders the run may write,
  and when the app's runs have all ended, it gives each such program a
  medium label of its own, so that it starts at medium integrity anywhere.
  The app's next low or `appcontainer` run labels them low again while it
  goes, so that the app may still write them.
- The data directory is labelled on the app's first low run, and stays so;
  a working directory inside it, as a shortcut's (the app's home), needs
  nothing more.
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

## Being told about updates

The daily check is a scheduled task, made with `schtasks.exe` from XML in UTF-16 (it
refuses UTF-8), starting `zigsaw-notify.exe` with the store and the task's name. That
program has the GUI subsystem, as a console program would flash a window. It runs
`zigsaw updates check` with no window, and shows the two lines that prints, if any,
with `Shell_NotifyIcon`, which needs no registration of the program with Windows.
What decides whether to tell, and what to say, is in zigsaw (`src/updates.zig`):
the notifier has no network code or task code, beyond removing a task whose store
is gone.

A check writes `updates\state.json` in the store: what's waiting, when it last told
and about what, and what was waiting when the user last looked. What's waiting is
compared with the store when it's read, so an app updated, held or gone back from
that version since the check isn't listed. An app that can't be checked keeps what
the last check found for it.

## Going back

`install` writes the ref it replaces to `versions\<id>.previous.json` before moving
the app's ref, so an install that stops between the two still has the replaced
version in one of them. `prune` adds those manifests to the blobs it keeps, and not to
the deployments it keeps, which are by layer and much larger. `rollback` reads the
previous version's image from the store (`Store.readCompleteImage`, which refuses an
image with a missing blob), asks as an update would about what it may reach beyond
the installed one, installs it with the source it came from, and writes the version
it left to `versions\<id>.skip.json`. Any install of another version deletes that.

These are files of their own, rather than fields of the ref, because refs and
overrides are parsed strictly: a zigsaw before 0.76 would refuse a ref with a field it
doesn't know, and on the same store, every ref. Each concern has its own file, so that
`hold` and an update never rewrite the same one.

`update` treats a held app as it treats one pinned by digest: a note, and no request.
With a skip, it asks the registry for the tag's digest first (`remote.manifestDigest`,
which resolves an index to its windows/amd64 image, as refs record), so that nothing of
the version passed over is downloaded or asked about.

## Lazy pulls

`pull --lazy` and `update --lazy` ([src/lazy.zig](../src/lazy.zig)) make an indexed
layer the store lacks, of 32 MiB or more, a deployment of Cloud Files placeholders,
after the signature check and the agreement and before the other layers download.
[The experiment](experiment-cloud-files.md) measured what this does and doesn't save.
It's a **bridge**: the placeholders last only until the layer is downloaded, and are
then replaced by the plain deployment a full pull makes. Keeping them would keep a
provider, its failure modes, and a cost the experiment couldn't explain: Windows
builds a hydrated DLL's image section anew for each process, 60 ms for llvm-mingw's
77 MB one, against 0.5 ms for a plain copy.

`pull` fetches the blob's tail, which has eStargz's TOC, checks the TOC against the
descriptor's annotation (the manifest is pinned by digest and its signature checked),
and refuses a layer whose names or entries a deployment couldn't have, as unpacking
would. It writes the tail and the descriptor to `lazy\<hex>\`, and starts the layer's
helper, `zigsaw lazy-helper <store> <hex>` ([src/LazyHelper.zig](../src/LazyHelper.zig)),
from a copy in `lazy\` named by its contents, so that zigsaw.exe can be replaced
meanwhile. The helper registers `deploy\<hex>\` as a sync root, makes a placeholder of
every directory and file (Windows then asks about no directory: all are there),
connects as the root's provider, and signals that it's ready; only then does `pull`
go on. The path an app sees never changes, so nothing else in zigsaw knows a lazy
deployment from another. Installing reads only the headers of the app's programs, to
pick their shims' kind, and reads those from the index rather than open a placeholder,
which would fetch the whole file: all their first chunks asked for at once, into
memory, so that neighbours share a request (TeX Live has 150 commands). `pull` holds
`lazy\<hex>.pull.lock` shared until it ends, and the helper's download waits for it,
so that the pull's other layers have the network first.

A separate process, as Windows lets one process provide for a root, and won't let that
process open the root's placeholders itself (error 395): `zigsaw run` couldn't be it.
**Windows asks the helper** for a range of a file, on its own threads, several at once.
The helper hands over the eStargz chunks that hold it, each whole (they start at
multiples of 4 MiB, as a transfer must), each checked against its digest in the TOC
before Windows sees it ([`Reader.readChunk`](../stargazer/src/estargz.zig), stargazer
0.3.0). **Every byte fetched goes into one file**, `lazy\<hex>\blob.sparse`, a sparse
file of the blob's size with its tail written in, and `lazy\<hex>\have` says which of
its blocks (1 MiB, or 64 KiB with a copy plan) are there
([src/BlobReader.zig](../src/BlobReader.zig)). A fetch asks
at once for the blocks of all its chunks that nobody has asked for; each run of them
goes out as one Range request, of 4 MiB at most, on four threads with a registry
client each: what Windows waits for first, the download's after. A fetch that wants
blocks another is fetching waits for those. A chunk read from the file that fails its
digest (a write cut short by a crash) has its blocks fetched again. Clients are
replaced every 64 requests, so that a helper that runs for hours neither grows nor
keeps an expired token.

**A fetch that waits tells Windows** how far it's got, every 2 seconds
(`CfReportProviderProgress`: the file's size, and what's come of the chunk so far, as
each request counts what it has received). Windows cancels a fetch that says nothing
for 60 seconds, which a 4 MiB chunk over a slow link, or a request queued behind four
others, may take. Iteration 79's probe found that any report restarts the 60 seconds,
a repeated one too.

**What the store has already isn't fetched** (0.79 on). Before it starts the helper,
`pull` plans the new blob from the store's other indexed layers, as a delta update does
(`remote.openOlds`, stargazer's `plan.make`): each member of the new blob that one of
theirs has, by chunk digest, is a copy. With at least a tenth copied, it writes
`lazy\<hex>\plan.json`: the copies, by where they go in the blob, and the blobs they
come from, by digest and size. Its helper then counts the blob in 64 KiB blocks rather
than 1 MiB, opens those blobs (leaving out one the store no longer has, or not at its
size), claims every block that runs of copies wholly cover (`BlobReader.claim`), and
copies them, in the blob's order, while holding the store's lock shared so that no
`prune` deletes a source. A run that wants a claimed block waits for the copy, not the
registry, and the download passes claimed blocks over. What lies between runs of
copies is fetched, in whole blocks, at most 128 KiB more for each. A copy that fails
has its blocks fetched; one that's wrong fails its chunk's digest when read, and the
whole blob's when the download ends, which then fetches it all again without the plan.

**The download** fills in the blocks the file hasn't, in order, 8 MiB a request, on at
most three of the threads, so that one is always free for Windows. It starts nothing
while a fetch for a run is queued or going, or for a second after one, as a run's next
read is often right behind; it skips what runs fetched; and a later helper goes on
from the map. Once every block is there, the file is hashed, stops being sparse, and
goes into `blobs\` if it's the blob, as for any pull, or is fetched again if not.

**Prioritized files**: if the layer has them (a recipe's [`prefetch`](recipes.md#recipes),
before `.prefetch.landmark`), the helper asks for their span as soon as it's connected,
at a run's priority, and has Windows hydrate each file (`CfHydratePlaceholder`, on a
handle that only reads attributes, which the provider's own process may open) as its
blocks are in. A first run then finds those on disk.
**The swap**: once no run uses the deployment (0.79 on: unpacking beside a run, with
Defender looking at each new file, made TeX Live's first `pdflatex` take 52 s instead
of 12), the helper unpacks the blob into `tmp\` as `Store.deploy` would, at background
priority (`PROCESS_MODE_BACKGROUND_BEGIN`: CPU, disk and memory) for a run that starts
meanwhile, with that folder's lock held so that `prune` leaves it, and waits until it can lock
`deploy\<hex>.lock` exclusively, which every run holds shared while it runs (and
`install` while it deploys). Then, with the store lock held shared so that no `prune`
comes between: it disconnects, renames the placeholders into `tmp\`, renames the
unpacked tree into their place, protects it, deletes `lazy\<hex>\`, and deletes the
placeholders, which Windows lets the helper's process do once it's disconnected. A
helper that ends between the two renames leaves no deployment and a complete blob,
which the next `deploy` unpacks as usual. A run that waits on the lock meanwhile finds
the plain deployment.

**Helpers come back**: each holds `lazy\<hex>.helper.lock` while it runs, beside the
folder it deletes. A run, a build using an image pulled lazily, and `pull` make sure
each lazy layer they use has one before they lock its deployment, under
`lazy\<hex>.start.lock` so that one starts. A new helper connects to the placeholders
its predecessor made, or registers the folder again if Windows forgot it. A helper that
gets nowhere for ten minutes while no run uses the deployment ends, and `list` says
it's paused. `rm`, `prune` and anything else that deletes a deployment stop its helper
first (a named event, then `TerminateProcess` after 15 s), then delete the placeholders
as any folder; Windows deletes what was never fetched with them.

**Jobs**: a zigsaw that a shim starts is in the shim's job, which the shim ends when
zigsaw ends. The shim's job allows breakaway, and the helper starts with
`CREATE_BREAKAWAY_FROM_JOB`, no console and none of zigsaw's handles (a GUI shim
reads zigsaw's output until every holder of its pipe has ended). The app's own job,
inside the shim's, allows nothing out, so what an app starts never leaves it. Where
some other job refuses breakaway, as GitHub's runners' does, the helper starts in it,
lasts as long as it does, and zigsaw says so.

**When a fetch fails**, the helper tells Windows, which fails the read, and writes
`fetch failed: <file>: <why>` to `lazy\<hex>\log`. An app only says what Windows told
it (`BAD_EXE_FORMAT` for a program or DLL), so a run that ends with an error prints
the failures the log gained while it ran.

## Signatures

zigsaw only checks signatures. Nothing in it can make one, or reads a private key: on
the publisher's machine, `cosign sign-blob` does the arithmetic, reached by the scripts
as a plain program from the store, since `zigsaw run` would put the passphrase on a
command line and could label the key's folder low.

An image's signature is what cosign's classic layout has: a tag `sha256-<digest>.sig` in
the image's repository, for a manifest with a layer per signature. The layer is a line of
JSON, the simple-signing payload, naming the image's digest and repository, and its
annotation holds the signature of those bytes, ECDSA P-256 over SHA-256, in base64 DER.
`src/signature.zig` has the rules and no I/O, `src/trust.zig` which keys count, and
`remote.checkSignature` what to fetch. A payload is checked in order: the signature
first, by each key for that repository, and only then what the now-trusted JSON says.
Both its fields matter. Without the digest, a signature of anything would do for
everything; without the repository, a signed image could be served as another app.

A signature goes beside an image and not in it, so signing moves no digest, nothing
rebuilds, and a zigsaw from before 0.74 doesn't notice. Tags are mutable, so
`signature push` takes the digest from the payload and never from the tag.

`remote.fetch` checks right after the manifest arrives, before the config or any layer,
when it's asked to install something (`consent` other than `.not_asked`). A build's
images come through the same function with `.not_asked`: `deps.zig` refuses anything but a
digest pin. `update --check` and the daily check don't look, so a tag moved to something
wrong is reported, and refused when someone goes to install it.

A release is the same arithmetic over the file `SHA256SUMS`, with the signature in
`SHA256SUMS.sig`. That file lists the zip and `VERSION`, and `upgrade.readSums` checks both
against it: otherwise a signed old release could be offered under a newer `VERSION`, which
would get as far as the new program saying its own version, and no further. Anything
that isn't there is `not_signed_yet`, as a release spends some time like that; a signature
by no key zigsaw knows is an error.

## How long grants last

What a run is granted on host paths, low labels and ACL entries, stays only
while a run of the app with nothing on its command line would be granted it
again:

- under the sandbox such a run gets ([above](#how-it-works)): its
  overrides', or its image's, or `low` (`soft` grants nothing);
- for the paths and folders its permissions and overrides name, and the folders of
  the volumes its overrides mount;
- for each working directory such runs had, while it keeps `cwd`, so that a
  big project isn't granted again on every run.

What a command line adds, with `--file`, `--filesystem` or `--sandbox`, is
taken back when the app's last run ends: one run that hands a file to
another, as Text Editor's does, leaves it to that one. What the app's
permissions or overrides no longer give goes as soon as `zigsaw override` or
an update takes it away, unless a run of the app is going, and then when the
last one ends. `zigsaw rm` takes back everything, and `zigsaw repair` what
an earlier zigsaw kept until `rm`, or a label on a folder that holds the
store, which zigsaw no longer gives. A run that didn't end (zigsaw was
killed) leaves its grants until the app's next run ends.

A store's `grants\<id>.txt` is what it goes by. Each is copied to
`HKCU\Software\Zigsaw\Grants`, one value per change, named `<store>|<app>|<change>`,
as Windows keeps a label after a store is deleted, which takes the file with it.
From that copy, `zigsaw grants` lists what any store changed, one store keeps a
label another still needs, and `zigsaw repair` takes back what a deleted store
left. A store counts as deleted when its `grants` folder is gone from a drive
that's there: one on a drive that's unplugged, or on a share, stays as it is. The
key goes when nothing's left in it.

The programs the app's runs wrote are listed in `grants\<id>.programs`:
medium between runs, low while its low and `appcontainer` runs go. `zigsaw
rm` forgets them, and they stay medium.

So a folder an app may write stays labelled low while the app is installed
with the permission, and each directory it ran in while it keeps `cwd`: any
low-integrity program may write there meanwhile. To keep an
`appcontainer` grant, save that sandbox: `zigsaw override
--sandbox=appcontainer <app>`. A sandbox given only on the command line
grants the app's folders afresh on each run, and takes them back after,
which takes a while for a big folder.
