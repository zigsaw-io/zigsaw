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
versions\<id>.data.json      which version left the data in snapshots\<id>
versions\<id>.data-owed.json the version whose data the app's next run is to copy
snapshots\<id>\        the app's data as an earlier version left it, for rollback
deploy\<hex>\          an unpacked layer, by layer digest, shared by all runs and apps;
                       placeholders while a lazy pull fetches it
lazy\<hex>\            a layer pulled lazily: its TOC, its download, what to copy from the
                       store's other layers, its helper's state and log
volumes\<id>\          an app's own volume: its data directory, per-app writable state, kept
                       across runs; a link instead, if a volume is mounted in its place
volumes\<name>\        a named volume's files, which outlive the data of the apps that mount it
volumes\<name>.json    a volume kept in a folder elsewhere: where
volumes\<name>.lock    held shared by each run that mounts the volume
data\<id>\             where a zigsaw before 0.85 kept an app's data, until it moves to volumes\
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
cache\work\<key>\      the record of a recipe's last build, which its next build goes on from:
                       what was built with which inputs, the prefix after each command, its size
                       (all of them together get ZIGSAW_KEPT_BUILDS_SIZE, 10 GB)
tmp\                   staging area, the data of --ephemeral runs, and build roots
                       (zigsaw-build-*): a recipe's last one among them, while cache\work has it
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
zigsaw starts the app with the same. Each shortcut's property store has
`System.AppUserModel.ID` = `Zigsaw.<app id>`, which a program can name as its
own (`SetCurrentProcessExplicitAppUserModelID`); Electron's runtime has each
app on it do so, as zigsaw can't from outside.

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
`LOCALAPPDATA` and `TEMP` point into `volumes\<id>\home`, and the user's folders
the app may use are directory junctions there, to the real ones. Windows
follows a junction as a path, and grants or denies access by what it
points to; deleting a tree or changing its ACL (inheritance) stops at the
junction. The working directory
is that home folder unless the app has the `cwd` filesystem permission. A job
object ends the whole process tree when the run ends. Deployed files deny
writes and deletes to the user, so no run, and nothing else running as you,
can change an installed app or runtime.

**Limits** are that job's (`process.Limits`), for a run and for each command
of a build, which has a job of its own. Windows asks no privilege for them,
and a job inside another gets the tighter of the two.

- `--memory` is `JOB_OBJECT_LIMIT_JOB_MEMORY`: the commit of all the job's
  processes together. Windows refuses what goes past it with the error a full
  page file gives (1455). The job has an I/O completion port, which hears
  `JOB_OBJECT_MSG_JOB_MEMORY_LIMIT`; zigsaw takes messages off it four times
  a second while it waits for the app, as the job also tells the port of
  every process that starts and ends. Windows doesn't promise every message,
  so the job's peak commit says it too: what was refused counts in it, so a
  job that reached its limit shows a peak at or over it. Without `--memory`
  there is no port, and zigsaw waits as before. `-v` prints the peak
  (`PeakJobMemoryUsed`), which a job keeps with or without a limit.
- `--cpus=N` is `JOB_OBJECT_LIMIT_AFFINITY`, a mask of N of the processors
  zigsaw itself may run on (so it is within an outer job's), chosen from
  `GetLogicalProcessorInformationEx`: one of each core before a second of any,
  the cores of the highest efficiency class first. The first 4 logical
  processors of this machine are 2 cores, and 4 busy processes took 9.2 s on
  them against 4.9 s on 4 cores. The job also gets a CPU rate hard cap of
  N/all, rounded up (`JobObjectCpuRateControlInformation`): the affinity keeps
  the job from reaching it, so it throttles nothing, and it is how Ninja
  counts processors. If Windows refuses the cap, the job goes without.
  `NUMBER_OF_PROCESSORS` and `CARGO_BUILD_JOBS` are set to N before the app's
  or the module's own variables, which win. N at or over what zigsaw has sets
  none of this.
- Every limited job gets the same processors: two `--cpus=4` builds at once
  share four.

**An app's data directory is its own volume**, `volumes\<id>\`: one of the store's
volumes, named by the app's id, which only that app mounts. It's listed, inspected,
removed and pruned as the others are; what tells them apart is who mounts what. An
installed app mounts its own, a saved `--volume` the one it names, and a volume
nothing mounts is what `volume prune` deletes. A named volume's name has no dot, and
an id nearly always has; an app whose id has none owns the volume of that name.

**Mounts** are junctions too, at the paths in `volumes\<id>\` that `--volume` names,
to a folder in `volumes\`, one elsewhere that `volume create --path` recorded, or
one of yours. One at `.` is a junction at `volumes\<id>` itself: the folder is then
the app's data, granted and labelled as a host path rather than as the app's own
volume, and the other mounts' links are made in it, after it, and taken away before
it. A run makes them before it joins the app's runs, while it can tell
whether another goes on: only then may it replace a link, or move the app's own
files into an empty volume (by renaming them, and then having the volume's ACL
inherited again, as moved files keep what they inherited where they were). The
folder is then one of the run's host paths, granted, recorded and taken back as
`--filesystem`'s are: a folder in the store is one no run may otherwise write
(below), but a volume's is the apps'. `grants\<id>.mounts` lists the links made, so
that the app's last run to end, or a change to its overrides, removes those no
saved mount names any more.

**A volume leaves the store as a tar**, and comes back from one (`zigsaw volume
export` and `import`, `src/archive.zig`). The archive is the folder's contents in
sorted order: an old-style tar header for each file and folder, with a pax header
before it where that falls short (a path over 255 bytes or not ASCII, a size from
8 GiB, the fraction of a second in a file's time), and one global pax header first
that says what the archive is of (`ZIGSAW.volume`, `ZIGSAW.app` and its version for
an app's own, the time). Zig's `std.tar`, which writes layers, has none of these.
Both commands hold the lock that says no run uses the volume (the app's runs lock
for its own, `volumes\<name>.lock` otherwise), and put back what a killed run left
in HKCU first, so an app's keys are in the archive. An export walks the folder as
the copy for a rollback does: never through a link, and for an app's own volume
without `cache\` and its temporary folder unless `--all`. An import checks every
name before it makes anything (no `..`, drive, stream, device name or character
Windows refuses), and unpacks into `.zigsaw-import-<random>\` inside the volume's
own folder: on its drive, and inheriting its label and ACL. Only then does it
rename the old files into `.zigsaw-replaced-<random>\` and the new ones up, one
name at a time, and delete the old; removing the import folder is what says the
renames are done. A failure before that deletes the import folder, and a failed
rename puts back the ones done. The volume's folder is never renamed, so its
grants, its record and a link to it stay. A leftover import folder (zigsaw was
killed while unpacking) is deleted by the next import and left out of an export;
both kinds of leftover at once mean it died between renames, and both commands
then refuse, naming the two folders.

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
hold; those on host paths go as [grants do](#how-long-grants-last). A run with the
camera device also holds Windows' capability for it, as the SID of the camera's
device class, which is what lets Media Foundation's camera service answer it
([findings](findings.md#devices-iteration-95)); the run's relay doesn't. (An entry for the
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

Before it writes any of that, an install that replaces a version copies the app's own
volume, `volumes\<id>`, to `snapshots\<id>` (`snapshot.keep`): the data as the replaced
version left it, which no run of the new one has touched yet. It holds the app's runs
lock exclusively meanwhile, so no run goes on, and first has `hkcu.settleLeftovers` put
the keys a killed run left in HKCU back into `registry\user.dat`, so that the copy has
them. The copy is made in `tmp\` and renamed into place, and `versions\<id>.data.json`,
which names the version and the manifest that left the data so, is written last: a copy
that stopped is a leftover `prune` deletes, and a record always has its folder. The walk
is zigsaw's own, not std's: it never enters a directory that is a reparse point, nor
copies one, so a mounted volume and a link to one of the user's folders stay out, and
the app's next run makes them again. `home\AppData\Local\Temp` and `cache` are left out.
Files go through `CopyFileW`, which keeps their times, attributes and streams, and on
ReFS (a Dev Drive) clones their blocks instead of copying them; the paths have the
`\\?\` prefix, as zigsaw's manifest doesn't ask for long paths. The walk makes the
folders itself and hands the files to up to eight threads, 2048 at a time: a small
file costs more to open and close than to copy, and 20,000 of them took 13 s one
after another (robocopy with one thread) and 6 s this way. If a run of the app goes
on, nothing is copied: `versions\<id>.data-owed.json` names the version, and the app's
next run that isn't `--ephemeral` takes the copy before it joins the app's runs
(`snapshot.beforeRun`), if it can lock them exclusively; if it can't, the new version
runs beside the old one, the data is no longer as the old one left it, and the debt is
dropped with a note.

`rollback` offers the copy only if its record's manifest is the previous version's, so
one an older zigsaw made stale by updating the app is never taken for what it isn't.
Taking the data back (`snapshot.swap`) is three renames under the runs lock: the app's
data to `snapshots\.swap-<id>`, the copy to `volumes\<id>`, and that folder to
`snapshots\<id>`, whose record then names the version left, with `set_aside`. The
record is deleted before the first rename, and written back if a rename fails. If
zigsaw stops in between, the app's next run, the next install or the next swap
finishes it (`finishSwap`): with nothing at `volumes\<id>`, the data goes back where
it was; otherwise only the last step was left. `prune` never deletes a `.swap-`
folder, whose name no app's id can be. The swap happens after the install, not before: a version
that doesn't install leaves the data alone, and a swap that fails leaves the version
gone back to, with `rollback --data-only` to try again. The data set aside keeps the
low integrity label and the links it had; the copy taken back has neither, and gets
them from the app's next run, as a new data directory does.

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

**What runs read** (0.96 on): `pull` writes the id of the image a layer is the own one
of, an app's or a runtime's, in its `layer.json`. Each time the helper has served a
file to a process other than itself, it appends `<layer hex> <path>` to
`learned\<id>.txt` in the store, once a file, under that file's lock (two versions of a
runtime can be lazy at once, each with its helper). The image's list is the paths of
the last three layers that file has lines of, by when each last got one
(`learned.select`); whoever reads it leaves the file with only those. When the image's
next layer is made lazy, `pull` says how many of the list's files it has, and its
helper asks for their spans in the blob as it starts (`lazy.learnedAhead`): those
within a MiB of each other as one, in the order runs first read them, less the
prioritized files. They go out at a priority of their own (`BlobReader.prefetchAhead`):
behind anything a run waits for, which moves a queued piece up if it wants it, before
the download, on at most three of the four threads, and counted apart (`ahead` in
`state.json`). On an update, blocks the copy plan claimed are passed over, so the list
costs requests only for what changed. The files stay placeholders: a run that reads
one gets it from the blob, in a callback that takes no request, and that callback is
how the helper sees the read and writes the file down for the new layer. A file that
no run reads any more is therefore gone from the list three layers later. Nothing is
seen once a layer is swapped in, and a layer nothing read from while it was lazy has
no lines and counts for nothing. `prune` deletes the lists of images that no installed
app is or has as a runtime; `rm` leaves them.

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

zigsaw only checks signatures. Nothing in it can make one, or reads a private key:
`cosign sign-blob` does that, keyless in CI (scripts/sign-images.sh, and
scripts/sign-release.sh --keyless), or with a key on a publisher's machine.

### Keyless

A keyless signature is a Sigstore bundle, as `cosign sign-blob --bundle` writes it: the
signature of a file, the certificate Fulcio gave the key that made it, valid for ten
minutes and naming who asked (for GitHub Actions, the workflow's URI at its ref, and in
an extension of Fulcio's, the issuer of the identity token), and the signature's entry
in Rekor's log with the log's promise of when it was entered (the SET).
`src/sigstore.zig` checks one with no I/O, against the trusted root built in
(`src/sigstore-root.json`, as Sigstore's TUF repository hands it out):

1. the entry is a hashedrekord 0.0.1, in a log whose key the root has, at a time that
   key was good for, and its SET verifies over `{"body","integratedTime","logID","logIndex"}`;
2. what the log entered (the body) names this file's SHA-256, this signature, and this
   certificate;
3. the certificate chains to a Fulcio authority of the root, checked at the log's time,
   which also says it hadn't expired when the file was signed; it's for code signing;
4. its key signed the file, and its SAN and issuer are exactly the identity wanted.

std's X.509 parser checks the chain, and skips the extensions zigsaw needs, which
`readExtensions` walks itself, bounds-checked, since a certificate is anyone's. Only
Rekor v1's entries carry a time the log vouches for: a Rekor v2 entry needs an RFC 3161
timestamp beside it, which zigsaw doesn't check, so it's refused, saying so. The
inclusion proof a bundle carries isn't checked; the SET is the log's word that the entry
is in it.

An image's keyless signature goes beside it under `sha256-<digest>.sigstore`: a manifest
whose layers are the payload, once, and a bundle per signature. What's signed is the
same simple-signing payload as below, and the checker makes it again from the repository
and digest rather than read it, so a bundle is good only for exactly that image in
exactly that repository. Not cosign's classic tag, because a zigsaw from 0.74 to 0.80
refuses what it can't check there, and not cosign's referrers, which zigsaw doesn't read;
here, a zigsaw before 0.81 finds nothing, and warns. `signature push-bundle` checks a
bundle as a pull would before it pushes, as a bundle that isn't good would have every
pull refuse the image.

Whose signature counts is `trust.Signer`: a key or an identity, per prefix. A release's
identity is built from the version being installed, so it names
`release.yml@refs/tags/v<that version>`: a release's signature can't stand for another's.
`readSums` takes `SHA256SUMS.sigstore.json` by that identity, or `SHA256SUMS.sig` by the
backup key, the way out should Sigstore's root change past what an old zigsaw knows. A
store's own keyless entries are a list of their own in `trust.json`, which zigsaws
before them skip.

### Keys

An image's signature by a key is what cosign's classic layout has: a tag `sha256-<digest>.sig` in
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
`SHA256SUMS.sig` (or keyless, above). That file lists the zip and `VERSION`, and `upgrade.readSums` checks both
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
