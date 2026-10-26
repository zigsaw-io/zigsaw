# Iteration 50: services, proxies, and AppContainer profiles one at a time

Built 2026-10-26. zigsaw 0.50.0. To publish: PostgreSQL and Kanboard
(republish, same versions).

## Outcome

- **Iteration 49's follow-up was clean.** The weekly run on the networking
  design's commit (40297068134, 56 min) was green in every job.
  - osm2pgsql is published, and its suite passed on Server 2025: 40 ok, 1
    known gap.
  - The AppContainer profile race that made iteration 49's run red didn't
    come back.
- **Slices 0 to 2 of [networking](networking.md)** (your pick; slice 3 waits
  for iteration 51):
  - **The profile race.** zigsaw creates AppContainer profiles one at a
    time, under a named mutex, and tries once more after a failure that
    isn't "already exists".
  - **Proxies.** Runs of apps with the network get your `HTTP_PROXY`,
    `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY`.
  - **Services.** An app declares what it serves, and its port is the same
    in every sandbox. Under `--sandbox=appcontainer`, zigsaw publishes it
    through a relay in the app's container.
- **Two known gaps closed:**
  - A client outside PostgreSQL's container reaches its server.
  - A browser reaches Kanboard under `--sandbox=appcontainer`.
- **New: `tests/netprobe.zig`**, the network probe, in the repository, and
  `tests/network.sh`, in CI's suites job, which prints the probe's report
  on Server 2025.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-50-agile-meerkat.md`):

- **Slices 0 to 2** (your pick, over all of 0 to 3 or only 0 and 1).
- **`${listen:<name>}` and `${port:<name>}`** (your pick, over `port` and
  `published`):
  - `${listen:<name>}` is where the app listens, and where its own runs
    connect.
  - `${port:<name>}` is where other programs reach it.
- Mine:
  - Services go in `permissions.services`, each with an export as its
    `command`.
  - Internal ports are kept in the store.
  - `--port=<service>=<port>` is a run option and an override.
  - The relay is a small program of its own, like the shim.
  - Gates: the relay can't accept a handed-in socket, or reach the app's
    internal port; serving needs zigsaw in each connection; postgres or
    PHP's server misbehaves behind the relay.

## What was built

### The profile race

[`appcontainer.zig`](../src/appcontainer.zig): `Profile.ensure` holds
`Local\zigsaw-appcontainer` while it creates a profile. A failure that isn't
"already exists" gets one more try after 100 ms.

Here, eight zigsaw runs started at once don't hit the race, not even 16,
with or without the fix: each run does enough before its profile to spread
them out. The fix rests on two things:

- the runner's failure (`0x80070003`, two runs at once);
- the probe's threads: 8 of them creating one profile fail 19 to 25 times
  in 40 calls, with `0x8007000a` or `0x8000ffff`.

`tests/network.sh` keeps a row of eight first runs at once.

### Proxies

[`environment.zig`](../src/environment.zig) passes the four variables
through when the run has the network, before the app's own variables, which
win. Windows' names are case-insensitive, so `http_proxy` is the same
variable. Builds still get their dead proxy.

### Services

The format, in [`oci.zig`](../src/oci.zig):

```json
"permissions": {
  "network": true,
  "services": [{ "name": "postgresql", "port": 5432, "command": "postgresql" }]
}
```

- `services` is optional, and left out of a config when absent, so other
  images' digests don't change.
- Checked in recipes and pulled configs:
  - names are lowercase letters, digits and `-`, each name and port once;
  - the export exists;
  - every `${listen:x}` and `${port:x}` in the app's `args`, `env` and
    export arguments names one of its services.
- `info`, and what `pull` and `build` show, say "serves postgresql on
  localhost:5432".
- A new service isn't counted as more access in an update's question.

Runs, in [`services.zig`](../src/services.zig) and
[`run.zig`](../src/run.zig):

- The ports are the declared ones, or `--port`'s (a run option and an
  override; an unknown service name fails, naming the app's).
- Under `appcontainer`, `${listen:x}` is the app's internal port:
  - random in 20000 to 48999, below Windows' dynamic range, and free when
    picked;
  - kept in `ports\<id>.txt` under a lock, so that the server and its
    clients agree.
- A run of the serving export publishes the service. So does a run of the
  app's command, when that runs the same program with the same arguments,
  as PostgreSQL's and Kanboard's do.
  - zigsaw listens on the port on `127.0.0.1` and `::1`, with
    `SO_EXCLUSIVEADDRUSE`.
  - It starts [`zigsaw-relay.exe`](../src/relay.zig) in the app's job, in
    its container, with the app's capability only, detached, and the
    sockets as its only inherited handles.
  - A port that's taken: "note: port 5432 is taken, so postgresql isn't
    published this run", and the app runs on.
- The relay (56 KB, ReleaseSmall, no `std.Io`):
  - accepts on each socket in a thread;
  - connects to the internal port, on `127.0.0.1` then `::1`, for up to
    2 s while the app starts;
  - copies both ways in two threads.
  It ends with the job. zigsaw keeps its own copies of the sockets until
  the run ends, which frees the port.
- [`process.zig`](../src/process.zig) got `startIn` (a process in another's
  job) and `inherit` (handles besides stdio).
- The relay is copied into the store's `relay` directory, named by its
  hash, so a running one is never replaced. It's granted to the app's
  capability like the app's own files.
- `zigsaw rm` forgets the app's internal ports. `prune` deletes those of
  apps that aren't installed, and older relays.
- The release has the relay too: `package.sh`, `install.ps1`, and the
  program lists of `tests/self.sh` and `tests/install.sh`.

Winsock's functions are in [`win32.zig`](../src/win32.zig), as Zig 0.16's
standard library keeps only its types. [`net.zig`](../src/net.zig) has
loopback listening and connecting with a timeout, for zigsaw, the relay and
the probe.

### The recipes

- [`postgresql.json`](../recipes/postgresql.json): `postgresql` on 5432,
  served by the `postgresql` export, and `PGPORT=${listen:postgresql}`,
  which postgres and libpq both read. Its layer is the published one
  (`039d068e`); only the config changes.
- [`kanboard.json`](../recipes/kanboard.json): `http` on 8471, served by
  `kanboard`, with `KANBOARD_LISTEN=127.0.0.1:${listen:http}` and
  `KANBOARD_URL=http://127.0.0.1:${port:http}/`, which
  [`serve.php`](../recipes/kanboard/serve.php) takes as its defaults.
  `--listen` still overrides both.

### Tests

- [`tests/netprobe.zig`](../tests/netprobe.zig) (`zig build netprobe`), the
  C probe's checks that matter here, in Zig. It's also `network.sh`'s app:
  `serve`, `ping` and `env`.
- [`tests/network.sh`](../tests/network.sh) (new, 33 s), in a store of its
  own:
  - the proxies, with and without the network, also in an AppContainer;
  - the race;
  - a host client reaching the service under soft, low and appcontainer,
    and the port free after the run;
  - `${listen}` and `${port}` in each sandbox, and the internal port kept;
  - `--port`, an override, an unknown service;
  - two runs in one container reaching each other without the network;
  - a port another program holds;
  - last, the probe's report.
- [`tests/postgresql.sh`](../tests/postgresql.sh): every run gets
  `--port=postgresql=<port>` instead of the server's `-p`. The
  appcontainer row "a client outside the container reaches the server in
  it" is a check now.
- [`tests/php.sh`](../tests/php.sh):
  - Kanboard runs with `--port=http=<port>`, and gets a row under
    appcontainer, which checks the address it prints is the published one.
  - The Composer row under low compared output that has had a grants note
    since iteration 41. It filters it out now, as `gtk3.sh` does.
- CI: `tests/network.sh` in the suites job.

## What Windows does here

`tests/network.sh`'s report, on Windows 11 26300.9711:

| check | result |
|---|---|
| same-container | connects |
| container-to-container | dropped |
| host-to-container | dropped |
| container-to-host | dropped |
| handed-listening | connects |
| handed-connected | connects |
| handed-unconnected | connects |
| profile-race | 19 to 25 of 40 calls failed, `0x8007000a` `0x8000ffff` |

The same as the C probe found. Server 2025's rows come from the next run.

## Results

| check | result | time |
|---|---|---|
| unit tests | 121 passed | |
| tests/network.sh | 13 ok | 33 s |
| PostgreSQL, fresh stores p and p2 | `7fc9d806` in both (layer `039d068e`, as published) | 40 s |
| Kanboard, fresh stores p and p2 | `8e1c29d0` in both | 38 s |
| tests/postgresql.sh (store p) | 49 ok, 0 known gaps (was 1) | 61 s |
| tests/php.sh (D:\zs\a) | Kanboard under appcontainer ok; Composer under low failed on the old note, fixed and checked on its own | 6 min 48 s |
| tests/sandbox.sh | 0 failed | 21 s |
| tests/shims.sh | 0 failed | 56 s |
| tests/matrix.sh (D:\zs\a) | 0 differ, the 3 known gaps | 2 min 19 s |
| `GROUP=base tests/build.sh` | 0 failed | 53 s |
| tests/install.sh | 0 failed: the package has four programs | 23 s |
| tests/self.sh | 15 ok: the relay is the same bytes as `zig build -Dstrip`'s, incremental too | 8 min |

## Decisions made along the way

- **The relay is a program of its own** (my call), not zigsaw's own
  executable. It's small, and like the shim it needs no `std.Io`; zigsaw's
  executable would have to be granted to every container where it is
  installed, a user's directory included.
- **Copies of the relay are named by their hash** (my call): a run can't
  replace a relay another run is using.
- **zigsaw keeps its copies of the published sockets until the run ends**
  (my call): it costs nothing, and the port is freed when the run ends,
  whatever the relay does.
- **The race fix has no profile-folder check** (my call, a deviation from
  the plan's "only if the profile's folder exists"): that takes the SID as
  a string. One more try covers a profile another run is finishing.

## Known gaps

- Services are on the loopback only. Under `--sandbox=appcontainer`, a
  service is published only while a run of its command lasts, and an app
  given a port of its own (`-p`, `--listen`) bypasses it.
- An app's internal port is kept until `zigsaw rm`: a program that takes
  it later keeps the app from listening.
- A zigsaw before 0.50 ignores services and leaves their placeholders as
  they are: the new PostgreSQL and Kanboard images need 0.50.
- Xdebug and osm2pgsql under `--sandbox=appcontainer` still can't reach
  this machine's programs: that's slice 3.
- On a runner, the relay is unproven until the next run, and Server 2025's
  probe rows are unseen.

## Next

- **Publish** `postgresql.json` and `kanboard.json` from `D:\zs\i50\p`,
  with `ZIGSAW=D:\zs\i50\bin\zigsaw.exe`, **before pushing**. CI's suites
  pull PostgreSQL at 18.6, and `postgresql.sh` passes `--port`, which the
  old image has no service for.
- Then commit, push, and tag v0.50.0.
- After that I read the run: network.sh's report and rows on Server 2025,
  postgresql.sh's appcontainer rows, and `scripts/check-pins.sh`.
- Iteration 51: slice 3, the loopback exemption (taken back like a grant)
  and forwards, with `uses` in recipes, for Xdebug and osm2pgsql.
