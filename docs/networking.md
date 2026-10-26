# Networking

Designed 2026-10-26, not built yet; the [decisions](#decisions) were
taken the same day. The facts below are from a probe run
unelevated on Windows 11 26300 (`netprobe.c`, kept outside the repository
for now). None of them has been checked on Server 2025.

## Today

- Apps have one permission, `network` (`permissions.network` in a recipe,
  `--share=network` and `--unshare=network`, overrides).
- Under `--sandbox=appcontainer`, a run with `network` holds the
  `internetClient` and `privateNetworkClientServer` capabilities. Without it,
  a run holds no network capability. This is the only sandbox that enforces
  the permission.
- Under `soft` and `low`, nothing is enforced: the app reaches whatever you
  can.
- Build steps get proxy variables that point nowhere, by convention. Vendor
  steps have the network.
- zigsaw's own requests honour `HTTP_PROXY` and `HTTPS_PROXY`. Runs don't
  pass them on, because a run's environment is built from scratch. An app
  behind a proxy that's set by variables can't get out.
- Four known gaps have one cause, AppContainer's loopback isolation:
  - Xdebug can't reach an IDE.
  - A browser can't reach Kanboard.
  - A client outside PostgreSQL's container can't reach its server.
  - osm2pgsql can't reach a server on this machine.

## What Windows does

From the probe. Every endpoint ran as a process of its own, and a check
passed only if a message went there and back.

| path | result |
|---|---|
| between runs in one AppContainer (one package SID) | works, with no network capability at all, and with different capabilities on each side |
| from one AppContainer to another | dropped (the connection times out) |
| from the host to an AppContainer, or from an AppContainer to the host | dropped, also through the machine's LAN address, and with every network capability |
| a listening socket the host made, handed to an AppContainer process | host clients connect, and the container accepts them |
| a socket the host connected, handed to an AppContainer process | the container talks to the host's server |
| `WSADuplicateSocket` into an AppContainer process that's already running | works |
| an unconnected socket the host made, handed in | the container connects it to the host, and to the internet with no network capability |
| AF_UNIX, between any two of host and containers | works, with no network capability. Only the socket file's ACL decides. Paths are limited to 108 bytes |
| a named pipe the host makes for one capability | opens only from a process that holds that capability |
| `OpenProcess` for memory writes and handle duplication | allowed within one AppContainer, even with different capabilities. Denied across containers |
| `CheckNetIsolation LoopbackExempt -a -p=<sid>`, unelevated (this account is in Administrators, with UAC's filtered token) | succeeded. The exempt container then reached the host, also through the LAN address. Connections into containers were still dropped |
| `CreateAppContainerProfile` of one new name, from 8 threads at once | some calls fail with `0x8007000a` or `0x8000ffff`, not "already exists". On the runner it was `0x80070003` |

Not tried yet:

- the exemption from a standard user;
- two exempt containers talking to each other;
- `-is`, the exemption's inbound mode.

The permission classifier stopped the last two. The probe's one exemption
was removed, and its profiles deleted.

So:

- **A container's runs already share a private loopback.**
- **A socket keeps the rights of the process that made it.** An unconnected
  socket handed into a container would bypass `network`.
- **Two apps in one container are one app.** Each can write the other's
  memory, so sharing a container isn't a way for two apps to talk.
- **The race explains iteration 49's red run.** PostgreSQL's suite starts
  its server and polls it with `pg_isready` at once, so two runs create the
  missing profile together.

## Principles

1. **One meaning in every sandbox, enforced by AppContainer.**
   - Without `network`, an app has only its own loopback: its runs reach
     each other, as psql reaches PostgreSQL's server.
   - With `network`, it has the internet, the LAN and this machine's
     servers, as Flatpak's `--share=network` does.
   - `soft` and `low` can't enforce either. Windows' filtering takes an
     administrator.
2. **Serving is declared.** An app that other programs reach declares a
   service: a name and a port. Clients use the same address in every
   sandbox.
3. **Apps never share a container.**
4. **Only connected sockets go into a container.** zigsaw makes those
   connections itself, outside, to what the app may reach.
   - An app can open any process in its container, so whatever a helper
     there holds, the app holds too.
5. **Nothing needs elevation.** What does stays the user's own step.

## Design

### Private loopback

Already so, and nothing changes. It gets documented, and a matrix row runs a
server and a client in one container with `--unshare=network`.

### Services: reaching an app in a container

A recipe declares what it serves, and which command serves it:

```json
"permissions": {
  "network": true,
  "services": [{ "name": "http", "port": 8471, "command": "kanboard" }]
}
```

- **The image gets two placeholders per service** (names to be settled):
  - one for where to listen;
  - one for where clients reach it, for a launcher that opens a browser.
- **Under `soft` and `low`, both are the declared port.** The app listens
  on it itself.
- **Under `appcontainer`, the app listens on an internal port** that zigsaw
  picks once per app and keeps in the store, so that every run of the app
  agrees on it.
  - A run of the serving command binds the declared port on `127.0.0.1` and
    `::1` itself, from outside the container.
  - It hands those listening sockets to a relay inside the app's container:
    zigsaw's own executable, in the run's job.
  - The relay accepts each connection, connects to the internal port, which
    is allowed within one container, and copies bytes both ways.
  - zigsaw needs no part in the relay after it starts.
- **A declared service is published on every run of its command** under
  `appcontainer`, with nothing to ask for.
- **`--port=http=9090` and overrides move the published port.** `info` and
  the install question name the services.
- **If the port is taken,** the run says so and goes on unpublished.
- **Services are on loopback only.** Serving the LAN needs a firewall rule,
  which takes an administrator.

PostgreSQL would declare `postgresql` on 5432, with `PGPORT` set from the
placeholder (postgres and libpq both read it). Its gap closes, and so does
Kanboard's. Passing `-p` yourself bypasses the placeholder, and so the
service.

### Reaching this machine from a container

There are two ways, and zigsaw uses both.

**(a) Loopback exemption.** Runs of apps with `network` get their container
exempted (`NetworkIsolationSetAppContainerConfig`), where Windows lets you.

- It's transparent: `localhost:5432` works as it does under `soft`.
- It's a setting of Windows' firewall service, outside the store, and it
  lasts. So it's handled like a grant: taken back when `network` is, and at
  `zigsaw rm` and `zigsaw repair`.
- It's all or nothing: an exempt app reaches every server on the machine.
  That's what `network` means in principle 1.
- It works for this account. A standard user's is untested.

**(b) Forwards.** An app declares what it uses: another app's service, or a
port on the host.

- A relay in its container listens on an internal port.
- For each connection, zigsaw connects to the target from outside and
  duplicates the connected socket in.
- It changes no system setting, and works for any user. It allows only what
  was declared.
- It isn't transparent. The target's port on `127.0.0.1` is taken, so the
  app must take another one, or a host, from its environment
  (`PGPORT`, `XDEBUG_CONFIG`...).
- zigsaw takes part in each connection.

**Decided: both.** The exemption where Windows allows it, and forwards
where it refuses.

- Recipes that use a local server declare it, so that the fallback has
  something to forward. osm2pgsql would declare PostgreSQL's service, and
  PHP would declare the host's port 9003 for Xdebug.
- A run says which way it went.

Either way, osm2pgsql reaches PostgreSQL in a container through PostgreSQL's
published service, and Xdebug reaches your IDE.

### AF_UNIX: an app-level complement

A placeholder for a socket directory in the store, granted to the serving
app and to the apps that declare using it. PostgreSQL would listen there
too (`unix_socket_directories`), and its clients would get `PGHOST`.

- It needs no relay, no port and no exemption.
- It works only for programs that speak AF_UNIX. Clients outside zigsaw,
  such as a JDBC tool, still need the service.

Later.

### Proxies

Runs of apps with `network` get `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`
and `NO_PROXY`, and their lowercase forms, passed on from your environment.

Apps without `network` get nothing, and under `soft` and `low` they stay
open (decided). The builds' dead proxy would make tools that honour proxies
fail fast there, but it would change the default sandbox for apps that work
today: Meld's git push, for one.

### Builds

Unchanged. Enforcing no network would mean running build steps in an
AppContainer, and several toolchains don't work there yet: Go's and
initdb's `NUL` on Server 2025, and kpathsea's long names, among others.

### Not in this design

- Serving other machines.
- Per-host rules (only `example.org`).
- DNS.
- Certificate trust. Each runtime has its own: Go, .NET, GLib and git with
  Schannel use Windows' stores; OpenSSL and Node have their own. That's a
  later audit, for networks that inspect TLS.

## Slices

0. **The profile race.** A named mutex around creating a profile, and
   deriving the SID after a failed creation. This fixes iteration 49's run.
1. **Proxies passed into runs.** The probe goes into the repository, and CI
   prints its rows for Server 2025.
2. **Services and the relay.** Kanboard and PostgreSQL declare theirs, and
   the suites drop two known gaps: curl to Kanboard, and a host psql to
   PostgreSQL in its container.
3. **Reaching this machine:** first the exemption, taken back like a grant,
   then forwards, with `uses` in recipes. Xdebug's and osm2pgsql's gaps
   close.
4. **Later:** AF_UNIX directories, and certificate trust.

## Decisions

Taken 2026-10-26:

1. **Reaching this machine: both.** The exemption where Windows allows it,
   and forwards where it doesn't.
2. **Services are published whenever the recipe declares them.**
3. **No dead proxy.** Apps without `network` stay open under `soft` and
   `low`.
