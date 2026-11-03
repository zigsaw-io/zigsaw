# Iteration 69: Knowing what's out of date

Built 2026-11-04. zigsaw's recipes pin their sources by hand, and nothing noticed a
new release. Now a report says which have newer versions and what each would
rebuild, and its first run found published images with critical security bugs,
which this iteration fixes. zigsaw **0.69.0**. 15 images to publish. How it's used is
in [published-apps.md](published-apps.md#whats-out-of-date), findings in
[findings.md](findings.md#upstream-versions).

## Outcome

- **The published PHP was on 8.5.11, and Kanboard on it.** PHP 8.5.12 fixes two
  critical unauthenticated remote code execution bugs (CVE-2026-109618,
  CVE-2026-109619), out since 2026-10-21. Kanboard listens on the loopback only, which
  limits who reaches it, not whether they can. Node's 24.22.1 and Kanboard's 1.2.55 to
  1.2.57 are security releases too. All are built here, and **reach no one until
  they're published**.
- **`scripts/check-upstream.sh`**: for each source, what's newer within its series and
  beyond, and how many images it would rebuild, down the pins. A minute, no tokens.
- **`scripts/upstream.txt`**: where to look, for all 176 source URLs and TeX Live's 432,
  with recipes untouched. A recipe's new source needs a row, which CI checks on every
  push, without the network.
- **The Upstream workflow** keeps the report in one issue, weekly.
- **`zigsaw update --check`**: what `update` would do, installing nothing.
- **Settings does list an app for `http`**, you found, and the default stays as it
  was. That closes iteration 68's open question, but for choosing it there.

## Starting decisions

Yours: script and table plus `update --check`; versions only, no advisories, as a blank
for a C library would read as safe; one issue; a checkpoint with the table, then leaves
and one security chain; Node + PHP + Kanboard and 7-Zip + fzf; build on `E:`; **leave
`session.upload_progress` on**, against PHP's advice, which it calls unlikely to matter.

Mine: recipes stay untouched, so the table moves no digest; one lookup, a URL and a
pattern around `{version}`; the pinned version must be found upstream, which shows a
row is right; newer versions never fail CI, broken rows and uncovered URLs do, and an
unreachable host is only reported.

Decided during (mine):

- **PHP's image is version `8.5.12-1`**, as PHP's zip is, though `php -v` says 8.5.12.
- **Its libraries are what PHP's list for 8.5 says**, not what's newest: so glib to
  2.90.1, sqlite3 staying at 3.53.4.
- **`php-deps` rows read that list**, so can't confirm the pin: `latest`.
- **Composer stays 2.10.3**, re-pinned: 2.11.1 wasn't asked for.
- **`exclude=`**, a row option the plan didn't have, for versions that aren't releases.

## What was built

- `src/update.zig` (`check`), `src/remote.zig` (`fetchInfoUnless`, `writeAddedAccess`),
  `src/main.zig`, version 0.69.0.
- `scripts/check-upstream.sh`, `scripts/upstream.txt` (154 rows), `tests/upstream.sh` (28
  rows, offline, also on Linux), `.github/workflows/upstream.yml`; `tests/upstream.sh`
  in Reproduce's pins job.
- 7 rows in `tests/registry.sh`, for `update --check`.
- The recipes below; README, docs/gaps.md, docs/findings.md, docs/recipes.md,
  docs/published-apps.md.

| Image | Version | Manifest |
|---|---|---|
| 7-Zip | 26.05 | `03835fd7` |
| fzf | 0.74.5 | `823c5396` |
| Node.js | 24.22.2 | `cab43fbb` |
| Prettier | 3.9.10 | `7dedf73c` |
| PHP SDK | 8.5.12-1 | `2e0bfb6e` |
| PHP | 8.5.12-1 | `8a904f33` |
| APCu | 5.1.28 | `73c0c85e` |
| Xdebug | 3.5.3 | `907b9fb5` |
| igbinary | 3.2.17RC1 | `5ffe3295` |
| redis | 6.3.0 | `33d0b4a7` |
| ssh2 | 1.5.0 | `f79a9156` |
| yaml | 2.3.0 | `3e924b5e` |
| zstd | 0.18.0 | `bdc76faa` |
| Composer | 2.10.3 | `a29589ee` |
| Kanboard | 1.2.57 | `cfb28c9c` |

## Results

- The same 15 manifests in fresh stores `E:\zs\i69\p` and `p2`.
- sqlite, make and zstd, unchanged, built on ReFS: the same as published from NTFS.
- Sources: Node's, PHP's and 7-Zip's match the checksums they publish, Prettier's npm's.
- As they report themselves: Node v24.22.2; PHP 8.5.12 with OpenSSL 3.5.9 and curl's
  Brotli 1.2.1; fzf 0.74.5; Prettier 3.9.10.
- `tests/php.sh` 46 ok, 277 s; `tests/registry.sh` 109 ok; `tests/upstream.sh` 28 ok;
  `tests/store.sh` ok; `tests/self.sh` ok, so zigsaw still builds itself byte-identical;
  `tests/matrix.sh` 0 differ, with its 3 known gaps; `zig build test` passes.
- The report, on Windows and on Linux, says the same.
- About a dozen rows against other sources (GitHub's release API, sqlite.org, PHP's
  `releases.json`, Rust's channel file, .NET's metadata): all right.
- After the bumps: 37 behind within their series, 7 with only a new series, 102
  current, 8 not checked, none broken.
- Defender: `zigsaw.exe`, `zigsaw-host.exe` and the deployments clean. As
  [before](findings.md#other-findings), this machine allows `Bearfoos.A!ml`, so that
  can't show that one.

The first version of the report was wrong in ways no test could see: six rows called
something newer that wasn't ([findings](findings.md#upstream-versions)). Reading it
found them, and the rows are fixed; a new row can do the same.

## First report

50 behind within their series, 9 with only a new series, 87 current, 8 not checked. The
last number is how many images it would rebuild. These come from the corrected table,
as the first run, on 2026-11-04.

| Upstream | Pinned → newest in its series | Rebuilds |
|---|---|---|
| busybox | 6075 → 6354 | 67 |
| zig | 0.17.0 → 0.17.1 | 45 |
| cmake | 4.4.4 → 4.4.5 | 32 |
| python | 3.14.7 → 3.14.10 (also 3.15.2) | 29 |
| pkgconf | 3.0.7 → 3.0.10 | 24 |
| libiconv | 1.19 → 1.19.1 | 19 |
| rust | 1.99.0 → 1.99.1 | 18 |
| sqlite | 3.53.4 → 3.54.1 | 18 |
| cargo-c, directx-headers, fribidi, gdk-pixbuf, glib, harfbuzz, libffi, libjpeg-turbo, libpng, libtiff, pcre2 | | 15 each |
| setuptools | 84.0.0 → 84.2.1 | 14 |
| freetype, glib-networking, hunspell, librsvg, libsoup, nghttp2 | | 13 each |
| **node** | 24.21.0 → 24.22.2 | 13 |
| **php** and 7 of its libraries | 8.5.11 → 8.5.12-1 | 11 |
| go | 1.27.1 → 1.27.3 | 6 |
| expat | 2.9.0 → 2.10.0 | 4 |
| gradle, mingit | | 3 each |
| **composer** | 2.10.3 → 2.11.1 | 2 |
| **7zip**, **fzf**, **kanboard**, kdsingleapplication, **prettier**, zot | | 1 each |
| dotnet-sdk, ungoogled-chromium, windows-sdk-contracts | | local |

In bold, what this iteration moved, but for Composer, only re-pinned. Only a new series:
at-spi2-core, Flameshot, ICU (held), Lua, OpenSSL (the 3.5 LTS, held), PostGIS, and PHP's
glib, ICU and sqlite3 as the directory had them. The whole of it now is
`bash scripts/check-upstream.sh --all`.

## Not checked

- **The Upstream workflow has never run**, nor has `gh issue edit` or the label: they
  need the workflow on the default branch. The script it runs was run on Linux.
- **CI on these images**, including `tests/upstream.sh` in the pins job, on your push.
- **`update --check` against ghcr.io**: its rows use a local zot.
- **7-Zip's file manager** on 26.05, only `7z`, and Kanboard in a browser, only what
  `tests/php.sh` asks it.
- **Choosing an app in Settings for `http`**, and following a link then.

## On this machine

I got this wrong, twice, and both are fixed:

- **My smoke run of 7-Zip labelled your real Desktop and Downloads low integrity** for
  about 8 minutes, as it ran without test folders set. While labelled, any
  low-integrity program could write in them. `zigsaw rm` took the labels back.
- **Your real Documents had been labelled since 2026-11-03**, by a probe of mine in
  iteration 68 (`D:\zs\i68\s1`, app `test.inner`), which that write-up didn't mention.
  `zigsaw rm test.inner` took it back. I found it only because I was checking the other
  two.

Afterwards `icacls` shows no label on Desktop, Documents, Downloads, Music, Pictures,
Videos or your profile. No file now in Desktop, Documents or Downloads was created or
written while they were labelled, so none can have kept a label. Documents itself last
changed at 23:00 on 2026-11-03, within that time, so something was added to it or removed
from it then, and what isn't known. **Deleting a store by hand keeps its labels**, so
`rm` its apps first; iteration 68 was wrong to call `D:\zs\i67\s` simply
deletable. Other old stores' grants under `D:\zs` and `E:\zs` name none of your folders,
by their records.

`E:\zs\i69` holds 13 GB of scratch, including the store to publish from. `D:` and `C:`
stayed as tight as they were.

## Next

- **Publish before pushing**, from the store that built them, soon, for PHP's sake:
  `ZIGSAW_HOME='E:\zs\i69\p' ZIGSAW='E:\zs\i69\bin\zigsaw.exe' scripts/publish.sh node.json php-sdk.json php.json php-apcu.json php-xdebug.json php-igbinary.json php-redis.json php-ssh2.json php-yaml.json php-zstd.json composer.json kanboard.json prettier.json 7zip.json fzf.json`
- Then commit and push (`git add --chmod=+x scripts/check-upstream.sh tests/upstream.sh`),
  and I read Reproduce. It re-checks the GTK and Qt families once, as the workflow file
  changed.
- **The push also schedules the Upstream workflow, which creates a public issue on its
  first run**, next Monday at the latest. Say if you'd rather I start it by hand, and I
  read the result.
- Tag **v0.69.0** after the push, and I read the Release run.
- Later: Go 1.27.3 with its 5 apps; Python 3.14.10 (29 images); BusyBox and Zig 0.17.1,
  which reach most images; advisories, which a report that knew PHP 8.5.12 was critical
  would have said louder; `session.upload_progress` at PHP's next release; a warning
  from `zigsaw` before a test store is deleted, or a way to list what labels a store holds.
