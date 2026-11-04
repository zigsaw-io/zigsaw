# Iteration 71: Knowing what's vulnerable

Built 2026-11-05. The Upstream report said which versions were behind, not which of them
mattered. Now it names the advisories OSV lists against each pinned version, and whether
the update clears them. Rebuilding in pin order, which every round did with a hand-written
script, is now `scripts/rebuild.sh`. And Go moved to 1.27.3, with zot on 2.1.23, as 16
advisories were listed against Go 1.27.1. zigsaw's code didn't change, so it stays **0.70.0**.
6 images to publish. How it's used is in [published-apps.md](published-apps.md#reading-the-advisories)
and [recipes.md](recipes.md#rebuilding-what-pins-what), findings in
[findings.md](findings.md#advisories).

## Outcome

- **Go 1.27.3 and its apps are built**, the same six digests in two stores with separate
  downloads and vendor steps. OSV lists nothing against the standard library any of the five
  programs now carries.
- **The report has "Known advisories" first**, and it's already useful: 15 pinned versions have
  some. Most clear at the newest in their series. zlib 1.3.2 has two heap overflows and no
  release to move to.
- **A 0 from OSV can mean it doesn't know.** It lists nothing for PHP 8.5.11, which iteration 69
  left for two critical RCEs. Older releases of PHP, PostgreSQL, Qt and GLib look the same, so
  they're marked `osv-thin` and the report says their 0 means nothing. This wasn't planned, and
  it's the main limit on the whole thing.
- **`standard-user` passes on a runner**, on its first real run (28 rows and nine suites as
  `zstest`, none failed, with the loopback exemption). `CreateProcessWithLogonW` works from an
  Actions step, which iteration 70 couldn't tell, so the fallback isn't needed.
- **That same run is red in `qt-suites`**: Notes showed no titled window in any sandbox. It isn't
  explained yet (see [Not checked](#not-checked)).

## Starting decisions

Yours: the security round over updates reaching people, signed images or the Cloud Files
bridge; rebuilding only Go and its 5 apps, with the rest left in the report.

Mine: the public issue lists advisories against published images; I start the Upstream workflow
by hand after the push; no severity scores; only IDs and a flag derived from vectors reach the
issue; zot moves too; `go.sum` isn't scanned by the report; zigsaw's version stays.

Decided during (mine, not in the plan):

- **`osv-thin`**, set by hand from what OSV lists for older tags. Without it the report would
  have said PHP looked clean.
- **The flag leaves out availability.** First it counted any high impact, which put three
  denial-of-service bugs in expat at the top of the table above a heap overflow in zlib. It's now
  a high loss of confidentiality or integrity, and the column says "data at risk". Those bugs
  are still listed.
- **A stand-in for the batch request in the tests**, not a file fixture, so they check the tags
  that were really asked about, and `{version_}` and `{sqlite}` in tag templates, which
  PostgreSQL and SQLite need.
- **`tests/qt.sh` says whether a program without a window was still running**, as the failing log
  couldn't tell a crash from a missing window.

## What was built

- `scripts/check-upstream.sh`: OSV's batch and records, `--new-advisories`; `scripts/upstream.txt`:
  `osv=` and `osv-thin` on 30 rows; `.github/workflows/upstream.yml`: a comment for new ones.
- `scripts/rebuild.sh`, `tests/rebuild.sh`, and that in the pins job; rows in `tests/upstream.sh`.
- `recipes/go.json`, `recipes/zot.json`; fzf, ORAS, skopeo and cosign re-pinned by `rebuild.sh`.
- `.github/workflows/reproduce.yml`: the 14-character password, in `86eb03f`.
- `tests/php/servers/servers.json` keeps its old Go: a test fixture, and that digest stays
  pullable under the 1.27.1 tag.

## Results

| Image | Digest | Time here |
|---|---|---|
| `org.golang.go` 1.27.3 | `fb6554b0d89f` | 34 s |
| `com.github.junegunn.fzf` 0.74.5 | `703f25eb6bc0` | 22 s |
| `dev.zotregistry.zot` 2.1.23 | `5d4b6d14fea0` | 6.5 min |
| `land.oras.oras` 1.3.6 | `90aa31a8a109` | 11 s |
| `io.podman.skopeo` 1.24.1 | `8a2f61641264` | 55 s |
| `dev.sigstore.cosign` 3.1.4 | `b3df72a5ae5f` | 4 min |

- Re-running `rebuild.sh` after zot's vendor hash stopped it took Go and fzf as cache hits, 0 s
  each, as designed.
- `tests/oci.sh`: 0 failed, and its 2 known gaps. `tests/registry.sh` against zot 2.1.23: 0 failed.
- `tests/upstream.sh` and `tests/rebuild.sh`: 0 failed, here and on Linux under WSL.
- Go's hash matches go.dev's. zot's commit string is the tag's, from the module proxy too.
- The live report takes about 90 seconds here. Go's row left "Known advisories"; I read seven
  of the records it listed, and they say what the report does.
- `go version -m` says `go1.27.3` in all five programs. What their own modules still carry is
  in [findings](findings.md#advisories): 1 to 20 each, skopeo the most.

`scripts/check-pins.sh` reports the new pins as missing until you publish. `tests/matrix.sh` and
suites unrelated to this weren't run: zigsaw's code didn't change, and CI runs them.

## Not checked

- **Why Notes opened no window on CI.** The only change in that commit was the password line. The
  job got a newer runner image, `20261103.298.1` where the last pass had `20261030.294.1`, but
  `gtk-suites` passed on that image too, and Designer and Linguist opened in the same job. So it's
  either the image and Notes together, or a flake. The next run re-checks Qt's family, and now says
  more. **If it's still red I'll look into it next, and it wouldn't be cosmetic: Notes is published.**
- **The Upstream workflow's new step**: `gh issue view`, the comparison and the comment need the
  workflow on the default branch. The first run writes the section and stays silent; a comment
  can only appear from the second.
- **Whether you'd get that comment.** It reaches those subscribed to the issue or watching the
  repository. The issue's author is the workflow's bot, so it's worth subscribing.
- **Whether each advisory applies here.** They're OSV's matches. I read a few: zlib's are in its
  `gz*` file functions, so what reaches them depends on the program.
- **`mawk`**: WSL's `awk` here is gawk. The patterns are POSIX, and the pins job will show.
- **v0.70.0's Release**, its scan and hashes: that's still to come, with your tag.

## On this machine

Scratch is in `E:\zs\i71` and `D:\zs\i71`. `E:\zs\i71\p` is what you publish from, so keep it until
then. `zigsaw grants`, with `ZIGSAW_HOME` on that store, lists low labels on `E:\zs\i71\cwd` and on
folders under `D:\zs\i71\tmp`, from runs and suites there: scratch, nothing of yours. The repository
has none. After you've published, deleting both folders and running `zigsaw repair` clears the record.

## Next

- **Tag v0.70.0**, on `86eb03f`. Notes' failure doesn't touch it: the same zigsaw passed that job
  hours earlier. I'll read Release and its scan, and compare its hashes with a build here.
- **Publish before pushing**, from the store that built them:
  `ZIGSAW_HOME='E:\zs\i71\p' ZIGSAW='E:\zs\i71\bin\zigsaw.exe' scripts/publish.sh go.json fzf.json zot.json oras.json skopeo.json cosign.json`
- **Then commit and push** (`git add --chmod=+x scripts/rebuild.sh tests/rebuild.sh`), and I read
  Reproduce, Qt's job above all. After that I start the Upstream workflow once and read the issue.
- **`zstest` can go**, as `standard-user`'s been read and only the Release comparison remains, which
  doesn't need it. In an elevated prompt, `net user zstest /delete`, and remove its profile under
  Settings, System, About, Advanced system settings, User Profiles.
- Next round, by what the report says: **CPython 3.14.10** clears everything listed but reaches 29 images;
  **libtiff 4.7.2 and libpng 1.6.59** clear theirs, in GTK's family; **zlib** has no release yet, and is in
  22 images; expat 2.10.0, 4 images.
- Later: PHP, PostgreSQL, Qt and GLib's own notices, which no report reads; `govulncheck` on built Go
  programs, which knows what's really called; updates that reach people who don't ask.
