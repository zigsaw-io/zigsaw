# Iteration 52: certificate trust, AF_UNIX's facts, and Java's release

Built 2026-10-27. zigsaw unchanged (0.51.0): this iteration changes images
and tests. To publish: 13 images, all of them republished (below).

## Outcome

- **Java is on Temurin's release.** Temurin 25.0.5+8 for Windows came out
  on 2026-10-22. All 8 Java images were on the early-access build
  (`25.0.5_7-ea`) that iteration 31 started on.
- **Apps trust what Windows trusts**, for a network that inspects TLS and
  adds its root CA to Windows: slice 4 of
  [networking](networking.md#certificate-trust), with
  [`tests/certs.sh`](../tests/certs.sh) checking it in each sandbox.
  - Java's images read the machine's roots in Windows' store.
  - Node adds Windows' to its own list.
  - MinGit no longer includes Git for Windows' system config, which this
    machine's git can set to OpenSSL and its bundle. It says Schannel
    itself.
  - The rest already read Windows' stores, but for five known gaps: PHP's
    curl, Composer, Perl, libpq's `sslrootcert=system`, and BusyBox's
    `wget`, which doesn't check at all.
- **AF_UNIX's facts are in the probe.** The feature waits for an app that
  needs it: PostgreSQL, the one that would have used it, names its socket
  by a port that differs under AppContainer.
- Iteration 51's push run (40378852208, 35 min) and the v0.51.0 Release
  were green. Server 2025's exemption rows were Windows 11's.

## Starting decisions

From the planning session (plan file
`let-s-plan-iteration-52-glowing-falcon.md`):

- **Networking slice 4** (your pick), with **the Temurin re-pin as slice
  0** (your pick).
- **AF_UNIX: the probe only** (your pick). The feature waits, as
  PostgreSQL's socket is named by its port.
- **Trust: images use Windows' store** (your pick), over zigsaw passing a
  bundle in, or only an audit.
- Mine: a test CA made for each run and taken out after, with nothing in
  the repository; zigsaw doesn't change.

## What was built

### Slice 0: Java on Temurin 25.0.5+8

- [`java.json`](../recipes/java.json) and
  [`java-sdk.json`](../recipes/java-sdk.json): version `25.0.5_8`, from the
  release's zips, with the sha256s Adoptium's API gives.
- Then, in order, each on the digests before it:
  1. Maven and Gradle;
  2. PDFBox and Scene Builder (on Maven);
  3. PlantUML and Logisim (on Gradle).
- Their own layers didn't change: only their configs did.

### Slice 1: AF_UNIX in the probe

[`tests/netprobe.zig`](../tests/netprobe.zig) got AF_UNIX endpoints
(`_unix-listen`, `_unix-connect`), a low-integrity place for them, as
`--sandbox=low` runs, and nine rows. Each runs in a directory of its own
under `TEMP`, which gives containers nothing but what the row grants.
`AF_UNIX` and `sockaddr_un` are in [`win32.zig`](../src/win32.zig); zigsaw
doesn't use them.

| check | Windows 11 26300.9711 |
|---|---|
| unix-host-to-container | connects |
| unix-container-to-host | connects |
| unix-container-to-container (no network capability) | connects |
| unix-not-granted | error 10013 |
| unix-read-only (read and execute only) | error 10013 |
| unix-low-to-host (a medium server's socket) | error 10013 |
| unix-host-to-low (in a directory labelled low) | connects |
| unix-path-107 | connects |
| unix-path-108 | connects |

So:

- only the socket file's ACL decides, and connecting writes to it;
- the file has its directory's label;
- paths take all 108 bytes.

[Networking](networking.md#af_unix-an-app-level-complement) has what a
design needs: PostgreSQL's port, clients that write, low labels, short
names.

### Slice 2: certificate trust

**The audit** found the trust of each image's TLS (the table in
[networking](networking.md#certificate-trust)). Most read Windows' stores.
Java (its `cacerts`) and Node (its list) didn't, and nor did:

- PHP's curl, Composer and Perl, with bundles of their own;
- libpq, whose `sslrootcert=system` looks in `B:\prefix\ssl`, where
  PostgreSQL's SDK was built, and finds nothing: it refused even
  ghcr.io's certificate, in every sandbox (with `sslnegotiation=direct`,
  libpq's TLS comes first, so any HTTPS server shows it).

MinGit's `etc/gitconfig` included `C:/Program Files/Git/etc/gitconfig`,
Git for Windows' system config, in every sandbox. Its TLS backend was
whatever that config said, here Schannel.

**The images:**

- **Java** ([`java.json`](../recipes/java.json),
  [`java-sdk.json`](../recipes/java-sdk.json)): `JAVA_TOOL_OPTIONS` gets
  `-Djavax.net.ssl.trustStoreType=Windows-ROOT-LOCALMACHINE`. This is a
  gate that was hit:
  - `Windows-ROOT`, the planned one, fails at low integrity with
    `KeyStoreException: error 5, Access is denied`: the JDK opens the
    user's store to write.
  - `Windows-ROOT-LOCALMACHINE` loads in every sandbox (57 roots).
  - Your call, LOCALMACHINE: a network's CA is the machine's, and in an
    AppContainer the user's own roots weren't there anyway.
  - 15 hosts verify from Java at low integrity, Maven Central, Gradle's
    and GitHub's among them.
  - The JRE has `jdk.crypto.mscapi`.
- **Node** ([`node.json`](../recipes/node.json)): `NODE_USE_SYSTEM_CA=1`.
  - 24.21 reads Windows' stores in every sandbox, at low too, and adds
    them to its list: 121 bundled, 121 from Windows (112 in an
    AppContainer), 242 in all.
  - Prettier and PHP's SDK (Node is a runtime of it) were re-pinned.
- **MinGit** ([`mingit.json`](../recipes/mingit.json)): a second module
  puts [`recipes/mingit/gitconfig`](../recipes/mingit/gitconfig) at
  `etc/gitconfig`: 2.56.0's, without the `[include]`, with
  `http.sslBackend = schannel`. Meld was re-pinned.

**[`tests/certs.sh`](../tests/certs.sh):**

- **The test CA.** Each run makes one with Git Bash's openssl:
  name-constrained to `localhost`, `127.0.0.0/8` and `::1`, valid for a
  day, with a certificate for `localhost`.
- **The servers.** [`tests/certs/server.py`](../tests/certs/server.py),
  on Python's image, serves HTTPS with it, and PostgreSQL's server its TLS.
- **Before Windows trusts the CA,** every client must refuse them, saying
  something of certificates or TLS (so it verifies, and nothing else
  broke).
- **With the CA in `LocalMachine\Root`,** each client must trust them,
  under soft, low and appcontainer: Python, Node, Java on the JDK and the
  JRE (a [`Get.java`](../tests/certs/Get.java)), MinGit, CMake, zig,
  psql, and PHP's streams and curl.
- **Known gaps:** PHP's curl, psql's `sslrootcert=system`, and `zig fetch`
  at low.
  - zig's std opens the store to write, too: `CertificateBundleLoadFailure`.
  - Its AppContainer rows pass `--share=network`, as zig's image has no
    network.
- **Elevation.** Adding the CA takes an administrator. CI's runners are
  elevated; elsewhere `CERTS_ELEVATE=1` asks through UAC.
  - Your call: not on this machine. Here only the rows from before it's
    trusted ran; the trusted ones run in CI's suites job.
- zig's std ignores the critical flag of extensions it doesn't know, so
  the CA's name constraints don't break zig's, or zigsaw's own, reading of
  the store while the CA is there.

## Results

| check | result | time |
|---|---|---|
| 13 images, fresh stores p and p2 | the same in both (below); Meld in p and `D:\zs\a`; the JDK, JRE, Node and PHP's SDK in `D:\zs\a` too | |
| tests/certs.sh, before the CA is trusted (`D:\zs\a`, today's images and then the new ones; psql in `D:\zs\i50\p`) | every client refuses, for its certificate | 20 s |
| tests/netprobe.zig's report | the AF_UNIX rows above | 24 s |
| tests/java.sh (store p) | 0 failed | 73 s |
| tests/matrix.sh (`D:\zs\a`, the new Node, MinGit and PHP's SDK) | 0 differ, the 3 known gaps (after the Python rows' host change, below) | 103 s |
| tests/gtk3.sh (`D:\zs\a`, the new Meld and MinGit) | 45 ok, 0 known gaps | 33 min (first runs granting the new deployments) |
| tests/php.sh (`D:\zs\a`, PHP's SDK on the new Node) | 44 ok | 6 min 26 s |
| tests/network.sh | 26 ok, the AF_UNIX rows in the report | 65 s |
| unit tests | 125 passed | |
| `GROUP=base tests/build.sh` | 0 failed | 54 s |
| zigsaw's programs, `-Dstrip`, HEAD and now | the same bytes | |
| scripts/check-pins.sh | 15 missing, all the new pins and versions; 0 older runtimes | |

| image | was | now | its own layer |
|---|---|---|---|
| `org.openjdk.java.Sdk` 25.0.5_8 | `e45ed698` (25.0.5_7-ea) | `e0e6bf20` | new (`2d9e66b9`) |
| `org.openjdk.java` 25.0.5_8 | `4d05838b` (25.0.5_7-ea) | `95555a36` | new (`41dda863`) |
| `org.apache.maven` 3.10.0 | `c5d44d38` | `05d74d8c` | the same |
| `org.gradle.gradle` 9.8.1 | `3e65c987` | `8050cb2a` | the same |
| `org.apache.pdfbox` 3.0.8 | `dcae2f4c` | `f689c842` | the same |
| `com.gluonhq.SceneBuilder` 26.0.0 | `db425890` | `a22abfeb` | the same |
| `com.plantuml.PlantUML` 1.2026.9 | `e10cf95a` | `6d928114` | the same |
| `com.github.reds.LogisimEvolution` 5.0.0 | `6de49650` | `7fb02700` | the same |
| `org.nodejs.node` 24.21.0 | `0a7a2c31` | `3f86c9eb` | the same |
| `io.prettier.prettier` 3.9.9 | `8eb376ad` | `d06b15e6` | the same |
| `net.php.php.Sdk` 8.5.11 | `aaff294a` | `b31be090` | the same |
| `org.git_scm.MinGit` 2.56.0.windows.1 | `636d59bc` | `c6457f01` | new (`85069d98`) |
| `org.gnome.Meld` 3.24.1 | `1324d175` | `d3082ef4` | the same |

## Decisions made along the way

- **Java's machine roots** (your call, at the gate): `Windows-ROOT` fails
  at low integrity.
- **And kept, over `cacerts` with an opt-in** (your call), after the
  matrix found what reading the store costs. Its Python row failed on
  example.com in every sandbox: Cloudflare now serves it on a chain to
  SSL.com TLS ECC Root CA 2022, which this machine's store hasn't got, as
  Windows hadn't needed it yet. Java on the machine's roots failed there
  too, where Java on `cacerts` and Node got 200.
- **The matrix's Python rows reach ghcr.io** (my call), not example.com:
  ghcr.io's root is in the store wherever zigsaw pulls, as zig's std reads
  the same store and fetches nothing.
- **No test CA on this machine** (your call): the trusted rows run in CI
  only.
- **A refusal counts only if it's about certificates** (my call): the
  first run passed four clients that had failed for something else (zig
  wanted a `build.zig`, Xdebug's stack hid PHP's warning, CMake printed
  only curl's code, Java its stack's last line).
- **PHP's SDK re-pinned to the new Node** (my call): Node is a runtime of
  it, which `scripts/check-pins.sh` would warn about. PHP's extensions keep
  their SDK pins, which don't warn.
- **Meld built in `D:\zs\a`, beside the fresh store** (my call): the GTK
  family is there already. Its own layer is the published one.

## Known gaps

- Those in [gaps](gaps.md): PHP's curl, Composer, Perl and libpq's
  `sslrootcert=system` keep their own trust; BusyBox's `wget` checks
  nothing; `zig fetch` fails at low; Java has only the machine's roots, and
  only those Windows has fetched; MinGit no longer reads Git for Windows'
  config.
- The trusted rows of `tests/certs.sh` haven't run anywhere yet: the first
  time is CI's run after the push. Server 2025's AppContainer rows for
  Node, Java, MinGit, CMake and zig are gated on `tests/acprobe.zig`, as in
  the matrix.
- AF_UNIX's rows are unseen on Server 2025 until that run.

## Next

- **Publish** from `D:\zs\i52\p`, with `ZIGSAW=D:\zs\i52\bin\zigsaw.exe`,
  in this order, **before pushing** (CI compares them and seeds the suites
  from them):
  1. java-sdk, java, maven, gradle, pdfbox, plantuml, logisim-evolution,
     scenebuilder;
  2. node, prettier, php-sdk;
  3. mingit, meld.
- Then commit (`git add --chmod=+x tests/certs.sh`) and push. Meld's change
  runs the GTK groups too. No zigsaw release: it didn't change.
- Then I read the run: certs.sh's trusted rows, the AF_UNIX rows on Server
  2025, and the java and GTK groups.
- Upstream drafts, for zig's std and the JDK's store at low integrity, are
  in `D:\zs\i52\up`.
