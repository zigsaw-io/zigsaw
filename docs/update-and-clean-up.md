# Updating and cleaning up

`zigsaw update` brings every installed app, or the ones named, up to date
with where it came from. An app built from a recipe is rebuilt from that
recipe file, so editing the recipe and running `update` installs the new
version. An app pulled by tag is pulled again if the tag now points at a
different image; only the manifest is fetched when it doesn't. If the new
image may reach more than the installed one, `update` asks first, as `pull`
does, unless given `--yes`; an app you don't agree to stays as it is, and
`update` exits with 1. An app pulled by digest is pinned and left alone, and
so is one you [hold](#going-back-and-holding).

`zigsaw update --check` says what `update` would find, and installs nothing. It
reads each tag's manifest, and the config of an image that's new, and no
layers. An app a new image waits for gets a line on stdout, followed by what
the new version may reach beyond the installed one; nothing on stdout means
there's nothing to update. Apps with nothing new get a note on stderr. A recipe
isn't built for this, so an app built from one only says so. It exits with 1 if
an app couldn't be checked, and with 0 otherwise, whatever it found:

```
> zigsaw update --check
org.nodejs.node 24.21.0 -> 24.22.2 (5e1c07a2 -> 91bd44f0)
com.example.Tool 1.4 -> 1.5 (0a93c6d1 -> 77e2ab10)
  permits    network
```

## Going back, and holding

An update that breaks something can be undone. When a new version of an app is
installed, by `update`, `pull` or `build`, the store keeps the blobs of the version
it replaced, and `zigsaw rollback <app-id>` installs that one again. It needs no
network, as everything is in the store already; its files are unpacked again, so it
takes about as long as an install that downloads nothing. Should the earlier version
reach more than the installed one, it asks first, as `update` does, unless given
`--yes`. The image was checked against its signature when it came in, and isn't again.

```
> zigsaw rollback com.github.junegunn.fzf
installed com.github.junegunn.fzf 0.74.4
  ...
went back: com.github.junegunn.fzf 0.74.5 -> 0.74.4 (sha256:703f25eb6bc0 -> sha256:4d8759253203)
  `zigsaw update` passes over 0.74.5 from now on, and takes a newer version; `zigsaw rollback com.github.junegunn.fzf` returns to it
```

From then on, `update`, `update --check` and the [daily check](#being-told-about-updates)
pass over the version you went back from, with a note, but not a newer one: when the
next version comes out, it's an update as any other. `rollback` again returns to the
version you left. `zigsaw list` shows `(previous <version>)` while there's one to go
back to, `(previous <version>, with data)` if its data is kept as well, and
`(skips <version>)` after a rollback.

Only one version is kept, the one the installed version replaced, and only its blobs:
`prune` keeps them, and deletes its unpacked files as before. `prune --previous` forgets
those versions, and deletes their blobs. A zigsaw before 0.76 doesn't know of them, and
its `prune` deletes them; `rollback` then says how to have the version back, as
`zigsaw pull <image>@<digest>` while its registry still has it.

**Its data can go back too.** An app that changed how it keeps its data, as
PostgreSQL's server does from one major version to the next, may not read it any more
after going back. So when an install replaces an app's version, zigsaw first copies the
app's data, [its own volume](#volumes), as that version left it, and says how much that
was and how long it took:

```
  kept     its data as 18.6 left it (39.9MiB in 978 file(s), copied in 280 ms), for `zigsaw rollback`
```

`rollback` then says what is kept, and asks whether the data is to go back with the
version. Its answer is no unless you say yes. Here between two images of PostgreSQL
18.6, a new cluster with one table:

```
> zigsaw rollback org.postgresql.PostgreSQL
org.postgresql.PostgreSQL's data as 18.6 left it just now is kept (39.9MiB in 978 file(s)). Taking it back sets aside what 18.6 wrote since, until the next update of the app.
Take its data back too? [y/N] y
installed org.postgresql.PostgreSQL 18.6
  ...
went back: org.postgresql.PostgreSQL 18.6 -> 18.6 (sha256:0198588f23b9 -> sha256:f0f2fa89b421)
  `zigsaw update` passes over 18.6 from now on, and takes a newer version; `zigsaw rollback org.postgresql.PostgreSQL` returns to it
  its data went back too, to how 18.6 left it just now; what 18.6 wrote since is set aside, and returns with `zigsaw rollback --data org.postgresql.PostgreSQL`, until the next update of the app
```

`--data` answers yes and `--keep-data` no, without asking; with nothing to answer, as
in a script, the data stays. Taking the data back swaps two folders in the store, so it
takes no time, and nothing is lost by it: what the newer version wrote since is set
aside in the copy's place, and going forward again, with `rollback --data`, brings it
back. If you left the data and the older version turns out not to read it,
`zigsaw rollback --data-only <app-id>` takes the data back without changing the version.

What to know about the copy:

- **One is kept for each app**, as one previous version is. The next install of the app
  replaces it, the data a rollback set aside included: the update says so when it drops
  that. `prune` keeps the copies and says what they take; `prune --previous` deletes them
  with the versions, and `rm` deletes an app's.
- **It's the app's own volume only.** A volume the app mounts and a folder of yours it
  may use are neither copied nor changed, and are there again after going back. An app
  whose data is mounted from elsewhere (`--volume=<source>:.`) gets no copy.
- **Its temporary files and cache are left out**, and start empty in data taken back.
- **It's taken while the app doesn't run.** If it runs when its version is replaced, its
  next run takes the copy before it starts, which a large one makes slower to start.
- **It costs the size of the data, and the time to copy it, at each update.**
  `zigsaw override --nosnapshot <app-id>` keeps an app's data from being copied, and
  `--snapshot` has it copied again; with `--global`, every app's. On a Dev Drive the
  copy shares its blocks with the data, and takes next to nothing of either.
- **It's no backup**: it's in the store, beside the data, and gone with the next update.

`zigsaw hold <app-id>...` keeps updates away from apps altogether, until
`zigsaw unhold <app-id>...`. `update` notes that a held app is held and leaves it, named
or not, and nothing contacts its registry: `update --check` and the daily check never
list it, and what a check found before goes from `zigsaw updates`. `pull`, `build` and
`rollback` still install what they're asked to, and the app stays held. `zigsaw list`
shows `(held)`. `rm` forgets all of this along with the app.

## Being told about updates

Nothing updates by itself: a program you depend on doesn't change between two runs
because a day went by. But a fix nobody hears about helps nobody, so `install.ps1`
starts a daily check, which only tells you:

- **What it is:** a scheduled task of your own, named `Zigsaw update check`, which
  needs no administrator, runs with your rights and only while you're signed in, and
  starts `zigsaw-notify.exe`, a program with no window. `zigsaw grants` lists it.
- **What it reaches:** once a day, the registry each of your apps came from, for that
  app's manifest and, if it's new, its config; and `github.com`, for a one-line file
  saying zigsaw's latest version and, if it's new, the signature that says so. No layers,
  so it's small on a metered connection too.
  It sends nothing that identifies you beyond what any request does, and a login you
  saved for a private registry goes to that registry as usual.
- **What it does:** if something's waiting, a notification says so. Clicking it opens
  a terminal listing what's waiting and the commands that install it. Nothing gets
  installed unless you run those.
- **How often:** a banner lasts seconds, and one you miss is gone, so what's waiting
  is told again every three days until you've looked at it, by clicking or with
  `zigsaw updates`. Something new is told at once. While Windows holds notifications
  back (full screen, Do Not Disturb) it waits for the next check. `zigsaw list` has a
  line about it too.

```
> zigsaw updates
Last checked 3 hours ago.

Waiting to be installed, with `zigsaw update`:
  org.nodejs.node 24.21.0 -> 24.22.2 (5e1c07a2 -> 91bd44f0)

zigsaw 0.74.0 is out; this is 0.73.0. `zigsaw upgrade` installs it.

A daily check is on; it installs nothing. `zigsaw updates off` stops it.
```

`zigsaw updates` only reads what the last check kept; `zigsaw updates check` looks
now. An app pulled by digest is pinned, one built from a recipe only rebuilding
can tell about, and one you hold is left alone: none is ever listed. Nor is a version
you went back from with `rollback`. `zigsaw updates off` removes the task and
remembers, in `updates\off` in the store; `zigsaw updates on` starts it again. A store
that isn't the default one gets a task only if `updates on` is run for it, and that
task, should the store be deleted, is removed by `zigsaw repair` or when it next runs.

`zigsaw upgrade` installs zigsaw's latest release, once you agree (or with `--yes`),
as `install.ps1` does, and more carefully: it checks the [signature](#signatures) of the
release's `SHA256SUMS`, the zip against that, starts the new program to see that it runs
here and is the version it should be, and only then replaces the old ones, moving those
that are running aside. Should anything go wrong before that, nothing changes. It never
runs by itself. It only replaces a zigsaw in its store's `bin`; one anywhere else, as a
build of your own, says how to install one instead, and isn't told about new releases.

## Removing what's old

Installing a new version deletes the files of the one it replaces, unless
that version is still running. `zigsaw prune` deletes everything else no
installed app needs: the blobs of old versions, files kept because they were
running, and whatever an interrupted build left in `tmp\`. It keeps the blobs
of each app's previous version, and the copy of the app's data as that version
left it, for [`rollback`](#going-back-and-holding), and
says how much they take; `--previous` deletes them too. `--dry-run` shows
what it would delete. Cached downloads, the runtimes that builds used,
build tools' caches and the [builds kept for the next one to go on
from](docs/recipes.md#going-on-from-the-last-build) stay unless you add
`--downloads`. The
[volumes](#volumes) nothing mounts, the data of uninstalled apps among them, are kept
unless you add `--volumes`; `prune` names them.

Nothing a running app uses is deleted, and zigsaw commands can run at the same
time: a run locks the files it uses, and `prune` waits for builds and pulls
to finish.
