# Iteration 57: the OCI tools

Built 2026-10-29. zigsaw unchanged (**0.56.0**). Three new images to publish:
ORAS, skopeo and cosign.

## Outcome

- **ORAS 1.3.6, skopeo 1.24.1 and cosign 3.1.4, built from source** with
  Go's image and BusyBox, from their module zips on proxy.golang.org, cgo
  off, with the version details their release builds stamp in. Each image
  is the same from two stores.
- **They work with zigsaw's registries and images**: ORAS pushes files from
  the working directory and pulls them back, skopeo lists, copies and
  (`--raw`) inspects an image zigsaw pushed, to a registry that wants a login
  and into an OCI layout, and cosign signs it with a key pair, offline, and
  verifies it; zigsaw still pulls the signed image. At the default sandbox
  (low), and in an AppContainer for what doesn't write to a path.
- **New suite, [tests/oci.sh](../tests/oci.sh)**, under tests/zot.sh, in
  CI's suites job.

## Starting decisions

From the planning session (plan file `plan-to-build-oci-shimmering-scroll.md`):

- **Own logins per app** (your pick, over sharing zigsaw's logins through a
  credential helper, or exposing Docker's config): each tool logs in for
  itself and keeps the login in its own data. No zigsaw change.
- **cosign with key pairs only** (your pick, over also trying keyless by
  hand, or keyless in CI).
- Mine: the newest releases, ids from the projects' own domains
  (`land.oras.oras`, `io.podman.skopeo`, `dev.sigstore.cosign`), and the
  three in the `rust-go` publish group with Go's image.

## What was built

### Slice 0: probe

Facts in [findings](findings.md#the-oci-tools-iteration-57), from builds
with Go's image and the programs run on the host against tests/zot.sh's
registries (scratch `D:\zs\i57`): skopeo's tags and policy lookup, cosign 3
refusing `--tlog-upload=false` and signing offline with a signing config
that names no services, skopeo taking zigsaw's images for artifacts, its
`oci:` tags needing an absolute path on Windows, and, in an AppContainer,
`EvalSymlinks` failing on the folders above the grant.

### Slice 1: recipes

- [recipes/oras.json](../recipes/oras.json): `go mod vendor` (12 MB).
- [recipes/skopeo.json](../recipes/skopeo.json): zot's pruned vendor step
  with skopeo's tags (32 MB of 46);
  [recipes/skopeo/policy.json](../recipes/skopeo/policy.json), accepting any
  image, as its default through `CONTAINERS_POLICY_JSON`.
- [recipes/cosign.json](../recipes/cosign.json): the pruned vendor step
  (103 MB of 130); `-buildid=` and the tag's commit date as its build date,
  as its Makefile does with `SOURCE_DATE_EPOCH`.

### Slice 2: tests/oci.sh

23 checks and 2 known gaps against the two zot registries, from a scratch
working directory: each tool's version; ORAS push, pull (same bytes), login,
push with it, logout and refused; skopeo list-tags, `inspect --raw`, login
and copy to the registry that wants one (checked with curl), logout, copy
into `oci:layout` and into a tagged layout by full path; cosign key pair,
signing config with no services and sign with a proxy that goes nowhere,
verify, verify with another key refused; `zigsaw pull` of the signed image;
in an AppContainer ORAS push, skopeo list-tags, cosign key pair and verify,
and ORAS pull and skopeo copy into a folder as known gaps; the repository
unlabelled. In a store with the three, 30 s; building them in a temporary
store first adds a few minutes.

### Slice 3: CI and documents

- [scripts/published-recipes.txt](../scripts/published-recipes.txt) and
  [published-groups.txt](../scripts/published-groups.txt): the three after
  zot, in `rust-go`.
- [tests/published.sh](../tests/published.sh): ORAS's and cosign's smoke
  runs are `version`.
- [reproduce.yml](../.github/workflows/reproduce.yml): the suites job pulls
  the three, and runs tests/oci.sh after tests/registry.sh.
- [published apps](published-apps.md), [recipes](recipes.md#the-oci-tools),
  [gaps](gaps.md), README's test list.

## Results

| check | result | time |
|---|---|---|
| the three recipes in store `p`, then in `p2` (downloads hard-linked) | same digests: ORAS `20cd9c75a52a`, skopeo `fbb808e6f372`, cosign `2a9c5a93095e` | 20 s, 24 s, 87 s with vendor steps cached |
| tests/oci.sh (`OCI_HOME=D:\zs\i57\p`) | 23 ok, 2 known gaps | 30 s |
| tests/oci.sh in a temporary store (BusyBox, Go and the three built first) | 23 ok, 2 known gaps; the store and work folder removed after | 7.6 min |
| `cosign login` to the registry that wants one, by hand | saved, unencrypted, in `data\dev.sigstore.cosign\home\.docker\config.json`; cosign has no `logout` | |
| scripts/check-pins.sh | the three missing (not published yet), nothing else | |

Not run: tests/published.sh, as the three aren't published (it only reports
an unpublished version, and smokes what it pulls); no other image changed.

## Known gaps

In [gaps](gaps.md): in an AppContainer, ORAS can't pull into a folder nor
skopeo copy into one; skopeo has no `containers-storage:`, cosign no
PKCS#11 or PIV, keyless signing untried; the tools don't see zigsaw's or
Docker's logins, and keep their own unencrypted in their data.

## Next

- Publish the three **before pushing** (CI's suites job pulls them):
  `scripts/publish.sh oras.json skopeo.json cosign.json` (with
  `ZIGSAW_HOME=D:\zs\i57\p`, which has them), and make the three new
  packages public on GitHub; then commit and push, and read the run:
  published (rust-go) with their smoke rows, and tests/oci.sh on Server 2025.
- Later, if wanted: a `registry-logins` permission handing an app zigsaw's
  logins through a credential helper, and keyless cosign.
