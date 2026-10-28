# Iteration 53: certificate trust, finished

Built 2026-10-28. zigsaw 0.53.0. To publish: 8 images (below), before the
push.

## Outcome

- **Iteration 52's run, fixed.** Its push run (40555087535) reproduced every
  published group, so the 13 images were on ghcr.io. It was red in two
  suites:
  - **certs.sh**, whose trusted rows ran for the first time:
    - `zig fetch` got through TLS, then stopped at the test server's
      missing `Content-Type`;
    - CMake refused the test CA's certificate: curl over Schannel checks
      revocation strictly, and the certificate named no CRL (found below);
    - Node's and the JDK's AppContainer rows passed where they were
      expected to be gaps.
  - **gtk.sh**: `gtk4-query-settings` printed nothing once. A rerun of the
    job passed, so it's a flake; the row now prints what it got.
- **Every image now trusts Windows' roots**, but for BusyBox's `wget`, which
  checks nothing, and `zig fetch` at low integrity:
  - **`${roots}`**, a new placeholder, is a PEM file of Windows' trusted
    roots that zigsaw writes for the runs (and builds) that name it, for
    programs that take only a file.
  - Through `SSL_CERT_FILE`, it's what PHP's curl, Composer, Perl and
    libpq's `sslrootcert=system` (psql, osm2pgsql) trust.
- AF_UNIX's rows on Server 2025 were Windows 11's.

## Starting decisions

From the planning session (plan file `plan-iteration-53-silly-scott.md`):

- **Close the trust gaps** (your pick).
- **`${roots}` from zigsaw** for the programs that take only a file (your
  pick, over leaving them as gaps). Iteration 52 chose images reading
  Windows' store over zigsaw passing a bundle in, but these have no store to
  read.
- Mine:
  - **libpq through `SSL_CERT_FILE`**, not a patched OpenSSL. PostgreSQL
    says `sslrootcert=system` is OpenSSL's default paths, which
    `SSL_CERT_FILE` overrides. OpenSSL 3.5.9 can read Windows' roots
    (`org.openssl.winstore:`), but nothing loads it by default, no variable
    turns it on, and it opens the store to write, which fails at low
    integrity, as zig's does. This way PostgreSQL's SDK isn't rebuilt.
  - **PHP's curl through `${roots}`**, not Schannel. Its `php_curl.dll` has
    Schannel too (`CURL_SSL_BACKEND=schannel` would pick it), but Schannel's
    strict revocation check is what refused CMake. Composer then gets the
    file from PHP's runtime.

## What was built

### Slice 0: CI's red rows

**The probe** (`D:\zs\i53\probe.sh`; nothing went in Windows' stores):

- A test CA, with one certificate that names no CRL and one whose CRL
  distribution point is on the test server.
- CMake's `file(DOWNLOAD)` against each, given the CA as `TLS_CAINFO`, so
  curl's Schannel checks the chain itself.

| certificate | soft | low |
|---|---|---|
| no CRL distribution point | `schannel: the revocation status is unknown` | the same |
| a CRL, served over HTTP | downloads | downloads |

`zig fetch` over plain HTTP from the test server worked once it said its
`Content-Type`.

**[`tests/certs.sh`](../tests/certs.sh)** and
**[`tests/certs/server.py`](../tests/certs/server.py)**:

- The test CA makes a CRL (`openssl ca -gencrl`), and the server's
  certificate names it. The server serves it over plain HTTP, as a
  well-run CA publishes one.
- The server sends a `Content-Type` for each answer.
- CMake's row prints Schannel's lines of curl's log when it fails.
- A gap row prints why, as a failure does.
- Node's and the JDK's AppContainer rows are no longer gated: they passed
  on Server 2025. The JRE's still is; its reason will show on the next run.

**[`tests/gtk.sh`](../tests/gtk.sh)**: the settings row prints the exit
status and the last lines it got.

### Slice 1: `${roots}` (zigsaw 0.53.0)

[`src/roots.zig`](../src/roots.zig):

- **What it reads.** The stores Python's `ssl` reads, the same way:
  - `ROOT` and `CA`, in each location Python opens (local machine,
    enterprise, group policy, current user, services, users);
  - opened read-only;
  - keeping what Windows trusts to identify servers: the purposes the
    store gives a certificate, or, if it allows any, those its extension
    names.
- **The file.** `<store>\certs\roots-<hash>.pem`:
  - sorted by each certificate's hash, without duplicates, so the same
    roots make the same file;
  - named by its contents, and written beside it then renamed, as the
    relay's copy is: a file a run has open never changes;
  - `zigsaw prune` deletes the others.
- **Who gets it.** A run makes the file only if its app's variables,
  arguments or exports, or its runtimes' or extensions' variables, name
  `${roots}`. A build only if a tool's variables do.
- **Its sandboxes.** zigsaw reads the stores itself, outside the run's
  sandbox. An AppContainer is granted read access to `certs\`, as to the
  relay's directory, and low integrity reads it as it is.
- `roots` can't be a runtime's alias.

Here: 64 certificates.

### Slice 2: the images

| image | change | was | now | its own layer |
|---|---|---|---|---|
| `org.perl.perl` 5.42.3.1 | `SSL_CERT_FILE=${roots}`; a name and summary | `0a4e1bd6` | `4bf63dc4` | the same (`80dc4de6`) |
| `net.php.php.Sdk` 8.5.11 | `SSL_CERT_FILE=${roots}`; `curl.cainfo = "${SSL_CERT_FILE}"`; no curl.se bundle | `b31be090` | `50ececfb` | new (`62f72c09`) |
| `net.php.php` 8.5.11 | the same, from the new SDK | `04d03b79` | `d4136222` | new (`a48cecfd`) |
| `org.getcomposer.composer` 2.10.3 | on the new PHP | `5f65e42b` | `11b4f09c` | the same (`42471c7c`) |
| `org.kanboard.Kanboard` 1.2.54 | on the new PHP and Composer | `8e1c29d0` | `85fc1b8d` | the same (`4b393eb0`) |
| `org.postgresql.PostgreSQL` 18.6 | `SSL_CERT_FILE=${roots}`; on the new Perl | `7fc9d806` | `21ee01b0` | the same (`039d068e`) |
| `org.osm2pgsql.osm2pgsql` 2.3.1 | `SSL_CERT_FILE=${roots}` | `ba27902d` | `b3c6c415` | the same (`5a79ed22`) |
| `org.tug.texlive` 2026.80721 | on the new Perl | `636af1ea` | `e4eb8aa4` | the same (`b41c89ee`) |

- Perl's image got its name now, as its digest changes anyway. Nine
  runtimes are left without one.
- PHP's extensions, pgvector, pg_cron, PostGIS, and the GTK and Gnumeric
  recipes that build with Perl keep their SDK pins, which don't warn.

**Tests:**

- [`tests/certs.sh`](../tests/certs.sh): two more clients, and the file.
  - Composer resolves `zigsaw/certs` from the test server's repository
    (`update --dry-run`, packagist.org off).
  - Perl's `HTTP::Tiny` gets `/ok`.
  - In each sandbox, a run reads `${roots}` and finds certificates in it.
  - PHP's curl and psql are expected to trust the CA now, not to be gaps.
- [`tests/php.sh`](../tests/php.sh): the runtime has no `cacert.pem`, and
  PHP's curl refuses php.net when `SSL_CERT_FILE` names another root.
- [`tests/store.sh`](../tests/store.sh): prune deletes a stale roots file.
- CI's suites store gets Perl, PHP and Composer, so their rows run there,
  trusted.

## Results

| check | result | time |
|---|---|---|
| 8 images, fresh stores `D:\zs\i53\p` and `p2` | the same in both (the table above) | |
| tests/certs.sh (store p), before the CA is trusted | 15 ok: every client refuses for its certificate, Composer and Perl too; each sandbox reads `${roots}` | |
| PHP's curl, Composer (`diagnose`), Perl's HTTP::Tiny, psql's `sslrootcert=system`, against php.net, packagist.org and ghcr.io | they verify under soft, low and appcontainer; with `SSL_CERT_FILE` naming an unrelated root, each refuses | |
| tests/php.sh (store p) | 45 ok | 8 min 36 s (with the extensions' builds) |
| tests/postgresql.sh (store p) | 49 ok, 0 gaps | 70 s |
| tests/osm2pgsql.sh (store p) | 43 ok, 0 gaps | 5 min 25 s |
| tests/texlive.sh (store p) | 20 ok, 1 known gap (pdfLaTeX in an AppContainer) | 104 s |
| tests/store.sh | 16 ok | 28 s |
| `GROUP=base tests/build.sh` | 91 ok | 42 s |
| tests/self.sh | 15 ok | 7 min 56 s |
| unit tests | 128 passed | |
| scripts/check-pins.sh | 6 missing, all the new pins; 0 older runtimes | |
| CI rerun of 40555087535's failed jobs | gtk-suites passed (the settings row's flake); suites failed on the same three certs.sh rows, which this iteration fixes | |

## Decisions made along the way

- **Composer's check resolves a package.** Composer reads a repository
  only for what it needs, so the test server's repository has one package.
- **php.sh's refusal uses another root, not an empty file.** An empty
  `SSL_CERT_FILE` is a case of its own: IO::Socket::SSL calls it
  "no certificate found", and HTTP::Tiny then gets through anyway. A file
  with one unrelated root makes Perl, PHP's curl, Composer and psql refuse.

## Known gaps

- Those in [gaps](gaps.md):
  - `${roots}` is Windows' roots when the run starts, and only those
    Windows has fetched (as Java's);
  - a zigsaw older than 0.53 leaves `${roots}` as it is: PHP's curl then
    refuses every connection, Composer and Perl use their bundles;
  - curl over Schannel (CMake, cargo) needs a CRL or OCSP responder;
  - BusyBox's `wget` checks nothing, and `zig fetch` fails at low.
- The trusted rows have run only in CI. This run is the first for Perl,
  PHP and Composer there, and for the CRL.

## Next

- **Publish** from `D:\zs\i53\p`, with `ZIGSAW=D:\zs\i53\bin\zigsaw.exe`,
  in this order, **before pushing** (CI compares them and seeds the suites
  from them):
  1. perl, php-sdk;
  2. php, postgresql, osm2pgsql, texlive;
  3. composer;
  4. kanboard.
- Then commit and push, and tag v0.53.0.
- Then I read the run: certs.sh's trusted rows (CMake with the CRL, PHP,
  Composer, Perl, psql), the JRE's AppContainer reason, and gtk.sh's
  settings row if it fails again.
