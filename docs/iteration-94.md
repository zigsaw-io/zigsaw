# Iteration 94: Only these hosts

Started 2026-11-12, from "plan to implement network allow list". Until now an app's network was
all or nothing: with `network`, an AppContainer run held `internetClient` and reached everything;
without it, nothing past its own loopback and the ports it uses. Now an app can reach a few hosts
and nothing else. Its recipe lists them (`permissions.hosts`), or you do (`--allow-host`). Under
`--sandbox=appcontainer` the list is enforced, without an administrator. zigsaw is **0.94.0**. No
image changes, so there's nothing to publish. How it's used is in
[the README](../README.md#allow-lists), how it works in
[networking.md](networking.md#allow-lists).

State at the start: 93 had landed (`de1d6ef`, Reproduce 43217577351 and Release v0.93.0 green).

## Outcome

- **`"permissions": { "hosts": [...] }`** in a recipe, and **`--allow-host=<pattern>`** /
  **`--noallow-host=<pattern>`** on `run` and `override` (also `--global`), layered as
  `--filesystem` and `--nofilesystem` are.
  - A pattern is a name, `*.<domain>`, an IPv4 address or an `[IPv6]` one, with an optional
    `:<port>`; without one, 443 and 80.
  - `--share=network` widens a list to the whole network; `--unshare=network` takes the network
    and the app's list away, so `--unshare=network --allow-host=github.com` narrows an app that
    has the network.
- **A run with a list holds no network capability.** Its relay is an HTTP proxy in its container
  (CONNECT, and requests for `http://` URLs, one per connection).
  - `HTTP_PROXY`, `HTTPS_PROXY` and `ALL_PROXY` name it, and `NO_PROXY` names this machine.
  - For each request **zigsaw**, not the relay, checks the list, resolves the name, connects
    outside the container and hands the connected socket in.
- **A name that resolves to this machine is refused**, listed or not: loopback, unspecified,
  link-local. A run reaches this machine only at an address its list names, or on the ports it
  uses.
- **What was refused, the run says when it ends**; the app gets `403` with the same reason. `-v`
  prints a line per connection.
- **Under `low` and `soft`** the proxy is there too, and a note says the list isn't enforced.
- **Your proxy** (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`) is used for a list's hosts:
  - through a CONNECT with Basic authentication, unless `NO_PROXY` names the host;
  - an `https://` or `socks5://` one gets a note, and zigsaw connects directly.
- **`info` and the install question** say "the network, only to …". An update that adds a host
  the old list doesn't cover asks first, as does going from a list to the whole network.

## Decisions

Yours, by the question dialog, all the ones I recommended:

- **Recipes and you**: `permissions.hosts` and the run options, over yours only.
- **Under `soft` and `low`, the same proxy and a note**, over making a list imply
  `appcontainer` or refusing to run.
- **CONNECT and plain `http://`**, over adding SOCKS5 or CONNECT only.
- **Through your proxy, in this iteration**, over later.

Mine:

- **The relay is the proxy, and zigsaw decides.** Windows filters connections by host only with
  an administrator. A container with no capability can't connect out, and a connection made
  outside and handed in works (the probe's new rows, below). That is iteration 51's forwards, with
  a host in place of a port.
  - The check is zigsaw's because the app can open the relay, as any process in its container,
    and so ask for anything itself.
- **Eight channels per run with a list**, each one request at a time, as forwards had one. A host
  on the internet takes seconds; one slow host would have held up every other connection.
- **Through your proxy, a CONNECT for plain `http://` too.** This changes the plan, which had the
  relay send a plain request to your proxy as it came. That needs your proxy's credentials in the
  relay, and the app can read the relay's memory. A tunnel keeps them in zigsaw. The cost: a
  proxy that refuses CONNECT to port 80 refuses plain `http://` under a list.
- **Names that resolve to this machine are refused**, so that DNS can't point a listed name at a
  server here. Private LAN addresses aren't refused: an intranet host is a fair thing to list.
- **A recipe can't have both `network` and `hosts`**, nor an empty list. A zigsaw before 0.94
  ignores `hosts`, and so gives such an app no network: it fails closed.

## Probe

`tests/netprobe.zig`'s report has five new rows, printed by `tests/network.sh` here and on CI:

| row | here (Win11 26300, unelevated) |
|---|---|
| `remote-from-host` (example.com:80) | connects |
| `remote-caps`, a container with the `network` permission's capabilities | connects |
| `remote-no-caps`, a container with none | error 10013 |
| `remote-handed`, a host-made connection handed to a container with none | connects |
| `remote-dns-no-caps`, resolving a name there | error 11001 |

The gate was `remote-no-caps` not connecting and `remote-handed` connecting; both held. The last
row means a run with a list can't even resolve a name, so a program that doesn't use the proxy
gets nothing. That is where the list's strength comes from, and its cost.

## Files

- `src/hosts.zig`: patterns, matching, what covers what (for the install question).
- `src/proxy.zig`: zigsaw's side. The list, resolving, names of this machine, your proxy
  (NO_PROXY, Basic authentication, CONNECT), what was refused.
- `src/relay.zig`: channels, `proxy=<port>`, the request's head, rewriting a URL's request, the
  proxy's own answers (400, 403, 502, 504). 68 KB, from 56.
- `src/forward.zig`: channels, proxy requests (`net.proxy_request`, `net.ProxyStatus`).
- `src/run.zig`: the run's network from `override.networkOf`, the proxy's port
  (`services.proxyPort`) and variables, the relay under every sandbox (with the low token under
  `low`), the notes.
- `src/oci.zig`, `src/override.zig`, `src/main.zig`: `permissions.hosts`, the settings, the
  options and help.
- `src/net.zig`, `src/win32.zig`: `GetAddrInfoW`, `net.resolve`, `Address.of`,
  `TryAcquireSRWLockExclusive`.
- `tests/hosts.sh` (new, CI after limits.sh); `tests/netprobe.zig`: `serve-http`, `fetch`,
  `fetch-http`, `fake-proxy`, and the remote rows.

## Results

| what | result |
|---|---|
| unit tests (`zig build test`, the relay's included) | pass |
| `tests/hosts.sh` (new) | 21 ok, 14 s |
| `tests/network.sh` | 26 ok, and the probe's new rows |
| `tests/sandbox.sh` | 142 ok, with TMPDIR on D: (NTFS); on the E: Dev Drive four label rows fail, as they did before this iteration |
| `tests/limits.sh`, `tests/shims.sh`, `tests/self.sh` | 0 failed |
| the package | `zigsaw.exe` `bfaf471c`, `zigsaw-relay.exe` `b07eac36`, 0.94.0; Defender finds nothing in its six programs |

By hand, with the probe as an app:

- Under `appcontainer`, a host it lists answers, one it doesn't gets `403` and the note.
- A direct connection is dropped.
- example.com answers, by name, over CONNECT and over plain http.
- Through the probe's proxy with Basic authentication, the tunnels show in its log. With NO_PROXY
  they don't. With a wrong password the app gets `502`. A `socks5://` ALL_PROXY gets the note.

## Not checked

- **Published images under a list.** The table of which programs use the proxy in
  [networking.md](networking.md#allow-lists) is from what each program documents. The suites
  ran the probe only. Node needs `NODE_USE_ENV_PROXY=1` in its image, and Java its proxy
  options; setting them means republishing, which is left for a later round.
- **A real corporate proxy**: NTLM or Kerberos, or one that refuses CONNECT to 80. The suite's
  proxy is the probe's, with Basic authentication.
- **IPv6 on the internet**: the rows and the suite use IPv4.
- **A standard user, and a CI runner**: `tests/hosts.sh` and the new probe rows run on CI for the
  first time with the push.
- **Under `soft` and `low` the proxy listens on this machine's loopback**, where any program of
  yours can use it to reach the app's hosts. Programs of yours reach them anyway.
- `tests/matrix.sh`, `upgrade.sh`, `rollback.sh` and the GUI suites weren't run.

## Yours to do

- Commit and push. I read the Reproduce run, `tests/hosts.sh` and the probe's `remote-` rows on
  Server 2025 first.
- The tag `v0.94.0` is yours; I read the Release run after it.
