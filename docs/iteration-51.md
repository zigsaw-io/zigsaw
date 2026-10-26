# Iteration 51: reaching this machine from a container

Built 2026-10-26. zigsaw 0.51.0. To publish: osm2pgsql and Xdebug
(republish, same versions).

## Outcome

- **Iteration 50's follow-up was clean.** Its push run (40328783135, 68
  min) was green in every job.
  - Server 2025's probe rows were the same as Windows 11's, with the
    profile race at 6 of 40 (`0x800703fa`, `0x8007000a`).
  - postgresql.sh had no known gap there, for the first time.
- **Slice 3 of [networking](networking.md)**, the last one planned:
  - **The loopback exemption.** Under `--sandbox=appcontainer`, a run of an
    app with the network has its container exempt from loopback isolation
    while the app's runs go, so it reaches this machine's servers.
  - **Ports an app uses.** An app, a runtime or an extension declares the
    ports on this machine it connects to (`permissions.uses`), and
    `${uses:<name>}` says where. In a container that isn't exempt, zigsaw
    forwards them.
- **Two known gaps closed**, both ways:
  - osm2pgsql reaches a PostgreSQL server on this machine;
  - Xdebug's step debugger reaches a DBGp client.
- `ZIGSAW_LOOPBACK_EXEMPTION=0` turns the exemption off.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-51-replicated-shell.md`):

- **Both ways**, as the networking design decided: the exemption where
  Windows allows it, forwards where it doesn't.
- **Xdebug declares 9003 itself** (your pick, over the exemption only for
  Xdebug): runtimes and extensions declare the ports they use, which join
  the runs that have them.
- **`${uses:<name>}`** (your pick, over `${connect:<name>}` and a shared
  `${port:<name>}`).
- Mine:
  - `uses` is a permission of its own: a declared port is reached with the
    network or without, as principle 4 says zigsaw connects to what the app
    may reach.
  - Services and uses share their names, for `--port`.
  - The tests' switch to forwards is a documented one,
    `ZIGSAW_LOOPBACK_EXEMPTION=0`, for whoever won't have the machine's
    setting changed.
  - Gates: Windows refusing the API unelevated; an exempt container without
    network capabilities reaching the host; the pipes or a duplicated
    socket failing in a container.

## What was built

### The probe first

[`tests/netprobe.zig`](../tests/netprobe.zig)'s report got the exemption's
rows, on a third container (`zigsaw.test.netprobe.c`) that it exempts and
takes back:

| check | Windows 11 26300.9711, unelevated |
|---|---|
| exempt-set | ok, 2 to 4 ms |
| exempt-to-host | connects |
| exempt-no-caps | connects |
| exempt-inbound | dropped |
| exempt-unset | ok, 2 to 3 ms |

The first gate passed. The second didn't: an exempt container reaches this
machine with no network capability at all. So, your call, the exemption
lasts only while the app's runs go, instead of standing between runs like a
grant: otherwise a run of the app without the network would reach this
machine too.

### The exemption

- [`appcontainer.zig`](../src/appcontainer.zig) `loopback`: `exempt`,
  `unexempt` and `isExempt`. Windows keeps one list for the machine, set
  whole, so they read it, change it and set it under a named mutex,
  `Local\zigsaw-loopback`.
- [`run.zig`](../src/run.zig): an AppContainer run with the network
  exempts the app's container before its placeholders are worked out.
  - It's recorded first, in `grants\<id>.txt` as the line `loopback`, as
    host grants are.
  - A container you exempted yourself isn't recorded, and stays.
  - If Windows refuses, the run says so, and goes on in a container that
    isn't exempt.
  - It works before the app's profile exists, on its first run.
- [`grants.zig`](../src/grants.zig): a `loopback` grant never stands, so
  the app's last run to end takes it back. `zigsaw repair` and `zigsaw rm`
  take back what a killed run left. `-v` tells both changes; other runs
  are quiet about them.

### Ports an app uses

The format, in [`oci.zig`](../src/oci.zig):

```json
"env": { "PGPORT": "${uses:postgresql}" },
"permissions": {
  "network": true,
  "uses": [{ "name": "postgresql", "port": 5432 }]
}
```

- `uses` is in `permissions`, and in a runtime's entry in an app's config,
  copied from the runtime's ([`deps.zig`](../src/deps.zig)). Both are left
  out when absent, so other images' digests don't change.
- Checked in recipes and pulled configs:
  - names as services', none of them a service's too, each port once;
  - an app's `${uses:x}` names one of its own or a runtime's;
  - a runtime's or an extension's names one of its own.
- A run's ports are the app's, then its runtimes', then its extensions':
  the first of a name wins ([`services.zig`](../src/services.zig)
  `usedBy`). `--port=<name>=<port>` and overrides move them, as services.
- `${uses:x}` is in every image's entries in a run: the app's, its
  runtimes' and its extensions'. Builds keep it as it is.
- `info`, `install` and what `pull` shows say "uses localhost:5432
  (postgresql)". An update that uses another port asks first.

### Forwards

When the run's container isn't exempt, and it uses ports:

- [`services.zig`](../src/services.zig) `forwardThrough` picks a free port
  for each, for the run only, from the internal ports' range, and
  `${uses:x}` is that port.
- The relay ([`relay.zig`](../src/relay.zig)) takes `forward=<in>:<out>`,
  two pipes it inherits, and `use=<port>` for each. It listens on those
  ports itself, inside the container, on 127.0.0.1 and ::1: a socket
  zigsaw made couldn't be reached from in there. Then it writes a byte.
- zigsaw starts the relay first, in a job of the run's, waits for that
  byte, and then starts the app in the same job
  ([`process.zig`](../src/process.zig) `newJob`). The app's first
  connection came before the relay listened, otherwise, and a connection
  to a port nobody listens on in a container is dropped, not refused.
- For each connection, the relay writes the use's index, under an SRW lock.
  [`forward.zig`](../src/forward.zig), a thread of zigsaw's:
  - connects to the port on 127.0.0.1, then ::1, for 2 s;
  - duplicates the socket into the relay (`WSADuplicateSocketW`);
  - answers with a status byte and the `WSAPROTOCOL_INFOW`;
  - keeps its own copy until the relay says it has opened its.
  The relay then copies bytes both ways, as for services.
- Only connected sockets go in. The relay holds the app's capability only.
- The thread ends with the relay, when the run's job does.

### The recipes

- [`osm2pgsql.json`](../recipes/osm2pgsql.json): `uses` postgresql on
  5432, and `PGPORT=${uses:postgresql}`. Its layer is the published one
  (`5a79ed22`); only the config changes.
- [`php-xdebug.json`](../recipes/php-xdebug.json): `uses` dbgp on 9003,
  `XDEBUG_CLIENT_PORT=${uses:dbgp}` in its env, and a build line that adds
  `xdebug.client_port=${XDEBUG_CLIENT_PORT:-9003}` to its `.ini`, which
  PHP reads (8.3's syntax). php-ext and PHP's SDK don't change. A user's
  `XDEBUG_CONFIG` with a `client_port` still wins.

### Tests

- [`tests/network.sh`](../tests/network.sh), with a server on the host
  that the probe app uses:
  - an AppContainer run with the network reaches it;
  - its container is exempt while the run goes, and not after;
  - without the network, or with `ZIGSAW_LOOPBACK_EXEMPTION=0`, it isn't;
  - a run that's killed (`taskkill /F`: bash's `kill` ends zigsaw as Ctrl+C
    does) leaves the exemption to `zigsaw repair`;
  - one you made with `CheckNetIsolation` stays;
  - `${uses:upstream}` is the port under soft, low, and when exempt;
  - when not exempt, a port of the relay's, through which the app reaches
    the server, without the network too, but not the port itself;
  - `--port` moves it.
- [`tests/php.sh`](../tests/php.sh): the debugger rows move `dbgp` with
  `--port` instead of `XDEBUG_CONFIG`. The appcontainer row connects now,
  and a new one connects through zigsaw with the exemption off.
- [`tests/osm2pgsql.sh`](../tests/osm2pgsql.sh): the appcontainer gap row
  is a check, and a new row imports through zigsaw with the exemption off,
  on `PGPORT` that `--port=postgresql=` moves.

## Results

| check | result | time |
|---|---|---|
| unit tests | 125 passed | |
| tests/network.sh | 26 ok, Windows' list empty afterwards | 61 s |
| Xdebug, fresh stores p and p2 | `858338d5` in both (layer `7e92d087`) | 95 s |
| osm2pgsql, fresh stores p and p2 | `ba27902d` in both (layer `5a79ed22`, as published) | 4 min |
| tests/osm2pgsql.sh (D:\zs\i49\p, osm2pgsql rebuilt there) | 43 ok, 0 known gaps (was 1) | 25 s warm, 5 to 6 min after a rebuild |
| tests/php.sh (D:\zs\a) | 44 ok, the debugger rows in every sandbox and through zigsaw | 8 min 20 s, mostly rebuilding the extensions |
| tests/sandbox.sh | 0 failed | 21 s |
| tests/shims.sh | 0 failed | 62 s |
| tests/ctrlc.sh, batch.sh, store.sh | 0 failed | 62 s, 9 s, 26 s |
| `GROUP=base tests/build.sh` | 0 failed | 52 s |
| tests/matrix.sh (D:\zs\a) | 0 differ, the 3 known gaps | 2 min 14 s (2 min 19 s before) |
| tests/install.sh | 0 failed | 3 min 27 s (it rebuilt the package) |
| tests/self.sh | 15 ok: the relay is the same bytes as `zig build -Dstrip`'s, incremental too | 6 min 47 s |

Every AppContainer run with the network in the matrix now exempts its
container and takes it back; that costs no time that shows.

## Decisions made along the way

- **The exemption lasts only while runs go** (your call, at the second
  gate).
- **The relay starts before the app** (my call): it has to listen before
  the app connects, and starting the app suspended would have needed its
  thread handle kept. Services' relay starts first too now; it connected
  lazily anyway.
- **Anonymous pipes, inherited** (my call), rather than a named pipe: no
  name to guard and no DACL, and the relay can't open anything else.
- **zigsaw keeps its copy of a forwarded socket until the relay has
  opened its own** (my call): one more byte, and no question of what
  closing it early would do.
- **`ZIGSAW_LOOPBACK_EXEMPTION` is documented** (my call), in `zigsaw
  help` and the README, rather than only a test switch.

## Known gaps

- Under `--sandbox=appcontainer`, a run of an app without the network is
  exempt too while another run of it with the network goes.
- The exemption is untested for a standard user's account. Where Windows
  refuses it, the run says so, and the app reaches only the ports it uses.
- An app in a container that isn't exempt reaches only the ports it
  declares: one given another port of its own bypasses the forward.
- A zigsaw older than 0.51 leaves `${uses:x}` as it is: the new osm2pgsql
  and Xdebug images need 0.51.
- On a runner, forwards are unproven until the next run, and Server 2025's
  exemption rows are unseen.

## Next

- **Publish** `osm2pgsql.json` and `php-xdebug.json` from `D:\zs\i51\p`,
  with `ZIGSAW=D:\zs\i51\bin\zigsaw.exe`, **before pushing**: CI builds
  both and compares them with what's published.
- Then commit, push, and tag v0.51.0. v0.50.0 wasn't tagged, so this would
  be the first release since v0.42.0.
- After that I read the run: network.sh's report on Server 2025 (the
  exemption rows), the php and osm2pgsql appcontainer rows, and
  `scripts/check-pins.sh`.
- Networking slice 4, later: AF_UNIX directories, and certificate trust.
