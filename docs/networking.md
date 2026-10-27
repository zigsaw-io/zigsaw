# Networking

Designed 2026-10-26; the [decisions](#decisions) were taken the same day.
Slices 0 to 2 were built in [iteration 50](iteration-50.md) (zigsaw
0.50.0): the profile race, proxies, and services. Slice 3, reaching this
machine from a container, in [iteration 51](iteration-51.md) (0.51.0).
Slice 4, in [iteration 52](iteration-52.md): what AF_UNIX does, from the
probe, and [certificate trust](#certificate-trust).
The facts below are from a probe run unelevated on Windows 11 26300, now
[`tests/netprobe.zig`](../tests/netprobe.zig), whose report
[`tests/network.sh`](../tests/network.sh) prints, on Server 2025 in CI too.

## Before

What was so when this was designed:

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
- zigsaw's own requests honour `HTTP_PROXY` and `HTTPS_PROXY`. Runs didn't
  pass them on, because a run's environment is built from scratch. An app
  behind a proxy that's set by variables couldn't get out.
- Four known gaps had one cause, AppContainer's loopback isolation:
  - Xdebug can't reach an IDE.
  - A browser couldn't reach Kanboard. (Closed by services.)
  - A client outside PostgreSQL's container couldn't reach its server.
    (Closed by services.)
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
| AF_UNIX, between the host and a container either way, or two containers (iteration 52) | works, with no network capability. Only the socket file's ACL decides, which it inherits from its directory: a client that may only read and execute it is refused (`10013`), as is a container not granted it at all |
| AF_UNIX, from a low-integrity process to a socket a medium-integrity one made | refused (`10013`): connecting writes to the socket file, which has its directory's label (medium, by default). The host reaches a low-integrity server's socket, in a directory labelled low |
| AF_UNIX paths | up to 108 bytes, all of `sun_path`, with no room for a NUL. PostgreSQL refuses a path of 108 or more |
| a named pipe the host makes for one capability | opens only from a process that holds that capability |
| `OpenProcess` for memory writes and handle duplication | allowed within one AppContainer, even with different capabilities. Denied across containers |
| `CheckNetIsolation LoopbackExempt -a -p=<sid>`, unelevated (this account is in Administrators, with UAC's filtered token) | succeeded. The exempt container then reached the host, also through the LAN address. Connections into containers were still dropped |
| `NetworkIsolationSetAppContainerConfig`, the API underneath, unelevated (iteration 51) | succeeds, in 2 to 4 ms; so does taking the exemption back |
| an exempt container with no network capability, to the host | connects: the exemption doesn't need `internetClient` or `privateNetworkClientServer` |
| the host to an exempt container | dropped |
| `CreateAppContainerProfile` of one new name, from 8 threads at once | some calls fail with `0x8007000a` or `0x8000ffff`, not "already exists". On the runner it was `0x80070003` |

Not tried yet:

- the exemption from a standard user;
- two exempt containers talking to each other;
- `-is`, the exemption's inbound mode.

The probe's report has the exemption's rows since iteration 51
(`exempt-set`, `exempt-to-host`, `exempt-no-caps`, `exempt-inbound`,
`exempt-unset`), on a container of its own that it exempts and takes back,
and AF_UNIX's since iteration 52 (`unix-...`), in directories under `TEMP`
whose ACLs it sets for each.

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

Already so, and nothing changes. `tests/network.sh` runs a server and a
client of an app without the network in its container, the client on
`${listen:<name>}`.

### Services: reaching an app in a container

Built in iteration 50. A recipe declares what it serves, and which command
serves it:

```json
"permissions": {
  "network": true,
  "services": [{ "name": "http", "port": 8471, "command": "kanboard" }]
}
```

- **The image gets two placeholders per service**:
  - `${listen:<name>}`, where the app listens, and where its own runs
    connect;
  - `${port:<name>}`, where other programs reach it, for a launcher that
    opens a browser.
- **Under `soft` and `low`, both are the declared port.** The app listens
  on it itself.
- **Under `appcontainer`, the app listens on an internal port** that zigsaw
  picks once per app and keeps in the store (`ports\<id>.txt`), so that
  every run of the app agrees on it. It's random, from 20000 to 48999,
  below Windows' dynamic range, and free when picked.
  - A run of the serving command binds the declared port on `127.0.0.1` and
    `::1` itself, from outside the container.
  - It hands those listening sockets to a relay inside the app's container:
    `zigsaw-relay.exe`, a small program of its own installed next to
    zigsaw's, copied into the store, and started in the run's job with the
    app's own capability, and no network one.
  - The relay accepts each connection, connects to the internal port, which
    is allowed within one container, and copies bytes both ways.
  - zigsaw needs no part in the relay after it starts. It keeps its own
    copies of the sockets until the run ends, which frees the port.
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

**(a) Loopback exemption.** Built in iteration 51. A run of an app with
`network` has its container exempted (`NetworkIsolationSetAppContainerConfig`),
where Windows lets you.

- It's transparent: `localhost:5432` works as it does under `soft`.
- It's a setting of Windows' firewall service, for the whole machine,
  outside the store. An exempt container reaches this machine's servers
  whatever its capabilities, so it lasts only while the app's runs go:
  each run with the network makes it, recorded in `grants\<id>.txt` as
  `loopback`, and the app's last run to end takes it back. Making it takes
  milliseconds. `zigsaw repair` and `zigsaw rm` take back what a killed
  run left. One you made yourself isn't recorded, and stays.
- It's all or nothing: an exempt app reaches every server on the machine.
  That's what `network` means in principle 1.
- `ZIGSAW_LOOPBACK_EXEMPTION=0` turns it off, for whoever doesn't want the
  machine's setting changed.
- It works for this account, and on GitHub's runners. A standard user's is
  untested.

**(b) Forwards.** Built in iteration 51. An app, a runtime or an extension
declares the ports it uses (`permissions.uses`): another app's service, or
a program of yours. `${uses:<name>}` is where the app connects for one.

- In a container that isn't exempt, the run's relay listens on a port of
  its own for each, inside the container, and `${uses:<name>}` is that
  port. zigsaw starts the relay before the app, and the app once the relay
  listens.
- For each connection, the relay asks zigsaw over a pair of pipes it
  inherits. zigsaw connects to the port from outside, on 127.0.0.1 or ::1,
  and duplicates the connected socket in (`WSADuplicateSocketW`). The relay
  copies bytes both ways.
- It changes no system setting, and works for any user. It allows only what
  was declared, with the network or without.
- It isn't transparent. The target's port on `127.0.0.1` is taken, so the
  app takes the relay's from its environment (`PGPORT`,
  `XDEBUG_CLIENT_PORT`).
- zigsaw takes part in each connection.

**Decided: both.** The exemption where Windows allows it, and forwards
where it refuses, or for an app without the network.

- Recipes that use a local server declare it, so that the fallback has
  something to forward. osm2pgsql declares PostgreSQL's port, and Xdebug's
  image declares 9003, which joins the runs of PHP and of apps with PHP.
- `-v` says which way a run went; a refused exemption is noted.

Either way, osm2pgsql reaches PostgreSQL in a container through PostgreSQL's
published service, and Xdebug reaches your IDE.

### AF_UNIX: an app-level complement

A placeholder for a socket directory in the store, granted to the serving
app and to the apps that declare using it. PostgreSQL would listen there
too (`unix_socket_directories`), and its clients would get `PGHOST`.

- It needs no relay and no exemption.
- It works only for programs that speak AF_UNIX. Clients outside zigsaw,
  such as a JDBC tool, still need the service.

Later: no app needs it yet, as services, forwards and the exemption close
the gaps it would. What the probe found (iteration 52) and a design has to
take in:

- **PostgreSQL names its socket by its port.** The file is
  `<dir>\.s.PGSQL.<port>`, with the `port` it listens on over TCP too.
  Under `appcontainer`, that's the server's internal port, while another
  app's client is told the declared port, or a relay's. It looks for
  another file. The server's socket would need the port clients are told,
  or clients the server's.
- **Clients write.** Each app that uses a socket needs Modify on the
  directory, not only read, and under `--sandbox=low` the directory needs
  the low label, for a low-integrity client to reach a server's socket, or
  a low-integrity server to make one.
- **Paths are short.** `<store>\sockets\<app id>\.s.PGSQL.5432` is 82 bytes
  in this account's default store, but the longest id published would make
  it 114. A directory named by the service, or by a hash, fits.

### Proxies

Built in iteration 50. Runs of apps with `network` get `HTTP_PROXY`,
`HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` passed on from your environment.
Names are case-insensitive on Windows, so those are also the lowercase
forms, such as curl's `http_proxy`. The app's own variables and `--env` win.

Apps without `network` get nothing, and under `soft` and `low` they stay
open (decided). The builds' dead proxy would make tools that honour proxies
fail fast there, but it would change the default sandbox for apps that work
today: Meld's git push, for one.

### Certificate trust

Built in iteration 52. A network that inspects TLS has a root CA of its
own, which its administrators add to Windows' trusted roots, for the
machine. **Apps trust what Windows trusts.** Most images' TLS reads Windows'
stores already; three images that didn't now do.

| image | TLS | trusts |
|---|---|---|
| zigsaw itself, and zig's image (`zig fetch`) | zig's std | Windows' roots. At low integrity, zig's std can't open them, as it asks to write: `zig fetch` there fails with `CertificateBundleLoadFailure` |
| GTK's runtime (libsoup), and the apps on it | glib-networking, with OpenSSL | Windows' roots and intermediates, read as glib-networking reads them (patched to read only, in iteration 12, for low integrity) |
| Python, and PyGObject's | OpenSSL | Windows' (the `ssl` module's default context), and `SSL_CERT_FILE` |
| MinGit, and Meld's git | Schannel | Windows'. **Changed:** MinGit's own `etc/gitconfig` included Git for Windows' system config, if this machine has Git for Windows, which can choose OpenSSL and its bundle. Its config no longer does, and says `http.sslBackend = schannel` |
| Node, and Prettier | OpenSSL | its own list, and **now** Windows' too: `NODE_USE_SYSTEM_CA=1` in its image |
| Java's images, and the apps on them | JSSE | **now** the machine's roots in Windows' store (`-Djavax.net.ssl.trustStoreType=Windows-ROOT-LOCALMACHINE`), instead of Temurin's `cacerts` |
| Go, and zot | Go | Windows' |
| Rust (cargo), CMake | curl, with Schannel | Windows' |
| Qt's runtime, Flameshot, Notes | Schannel | Windows' |
| VLC | GnuTLS | Windows' |
| .NET's images, Files, Pinta | Schannel | Windows' |
| PHP | OpenSSL | streams: Windows' (`openssl.cafile` isn't set). curl: its bundle, `extras\ssl\cacert.pem` (a known gap) |
| Composer | PHP's | its own bundle, unless `SSL_CERT_FILE` names one (a known gap) |
| PostgreSQL's libpq (psql, osm2pgsql) | OpenSSL | `sslrootcert`, by default `root.crt` in the app's data. `sslrootcert=system` finds no roots: OpenSSL looks where the build was, `B:\prefix\ssl` (a known gap) |
| Perl | IO::Socket::SSL | Mozilla::CA's bundle, or `SSL_CERT_FILE`. Its image has no network |
| BusyBox's `wget` | BusyBox's own | it doesn't check certificates at all. Its image has no network |

The others (GDAL, TeX Live, ripgrep and the rest) make no TLS connections.

- **Java has the machine's roots, not the user's.** `Windows-ROOT`, which
  has both, can't be read at low integrity: the JDK opens the user's store
  to write (`KeyStoreException: error 5`). A network's CA is the machine's.
  In an AppContainer, reading the user's stores gave the machine's
  certificates only anyway, to Java and to Node (Java: 57 roots there
  against 58 outside, the 58th being in this account's own store).
- **Java and Python trust only the roots Windows already has.** Windows
  fetches a root it lacks when one of its own programs checks a chain;
  Java and Python read the store, which doesn't. Java no longer has
  `cacerts`'s other roots (decided knowing it): here, example.com's root
  wasn't fetched yet, and Java and Python failed there where `cacerts` and
  Node didn't. The 15 hosts checked from Java at low integrity verify,
  Maven Central, Gradle's and GitHub's among them.
- **Checked by [`tests/certs.sh`](../tests/certs.sh).** It makes a test CA
  for the run, name-constrained to `localhost`, `127.0.0.0/8` and `::1`.
  Every client must refuse its server until the CA is in the machine's
  Trusted Root store, and then trust it under soft, low and appcontainer.
  Adding it takes an administrator, so the trusted rows run on CI's
  runners, which are elevated.

### Builds

Unchanged. Enforcing no network would mean running build steps in an
AppContainer, and several toolchains don't work there yet: Go's and
initdb's `NUL` on Server 2025, and kpathsea's long names, among others.

### Not in this design

- Serving other machines.
- Per-host rules (only `example.org`).
- DNS.

## Slices

0. **The profile race** (built). A named mutex around creating a profile,
   and one more try after a failure that isn't "already exists". This fixes
   iteration 49's run.
1. **Proxies passed into runs** (built). The probe is in the repository,
   and CI prints its rows for Server 2025.
2. **Services and the relay** (built). Kanboard and PostgreSQL declare
   theirs, and the suites dropped two known gaps: curl to Kanboard, and a
   host psql to PostgreSQL in its container.
3. **Reaching this machine** (built in iteration 51): first the exemption,
   while the app's runs go, then forwards, with `uses` in recipes.
   Xdebug's and osm2pgsql's gaps closed.
4. **AF_UNIX, and certificate trust** (built in iteration 52): AF_UNIX's
   facts in the probe, for a design later, and the images that kept CAs of
   their own trusting Windows' too.

## Decisions

Taken 2026-10-26:

1. **Reaching this machine: both.** The exemption where Windows allows it,
   and forwards where it doesn't.
2. **Services are published whenever the recipe declares them.**
3. **No dead proxy.** Apps without `network` stay open under `soft` and
   `low`.

Taken for iteration 51, the same day:

4. **`${uses:<name>}`**, the placeholder for where an app connects for a
   port it uses.
5. **Xdebug declares 9003 itself**, so runtimes and extensions declare the
   ports they use, which join the runs that have them.
6. **The exemption lasts only while the app's runs go**, rather than while
   its overrides give it the network: the probe found that an exempt
   container reaches this machine without any network capability.
