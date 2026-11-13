# Testing

```bash
zig build test          # unit tests
bash tests/matrix.sh    # runs real tools through the three sandboxes (Git Bash, network)
bash tests/sandbox.sh   # which sandbox a run gets (low by default, the image's, store-wide and app overrides); what the low and appcontainer sandboxes change on the host, how long it lasts, and rm undoes; a working directory low won't label, read-only; --file; your folders (fake ones); registry keys kept with an app
bash tests/network.sh   # an app's service reached from the host in each sandbox, on its port, one --port or an override moves it to, and not after the run; in an AppContainer, an internal port the app's runs agree on and reach each other on without the network, and a port another program holds; an AppContainer run with the network exempt from loopback isolation while it goes (not without the network, nor with ZIGSAW_LOOPBACK_EXEMPTION=0), a killed run's exemption taken back by repair, one you made kept; a port the app uses reached directly, or through zigsaw's forward when not exempt, and --port moving it; proxy variables passed to runs with the network; eight first AppContainer runs at once; the probe's report of what Windows lets AppContainers do on the loopback and over AF_UNIX (tests/netprobe.zig)
bash tests/reach.sh     # what a run may reach of the rest of the machine: the store's commands on its PATH, each running as its own app; zigsaw-host, your real environment with the run's rights; an image saying it can't run under a sandbox; URL schemes and Default apps in a scratch key, and one private scheme followed through Windows, which rm removes (30 s; opens a console for a moment)
bash tests/ps.sh        # zigsaw ps: runs in each sandbox, through a shim, one inside another, one whose zigsaw was killed, a build's command; --processes and filters
bash tests/stop.sh      # zigsaw stop and kill: Ctrl+C to runs in each sandbox, each in a terminal of its own (pseudoconsoles, tests/ctrlc.zig), an app that ignores it, another program on the run's console, a stop typed in the run's own terminal; kill, several runs, a run inside another, builds (30 s)
bash tests/limits.sh    # --memory and --cpus on runs, in each sandbox, saved as overrides, through a shim, and on builds; what zigsaw says when a limit is reached
bash tests/devices.sh   # an app's devices: the camera's capability in an AppContainer run's token and no other, --device and --nodevice, overrides, a relay that holds none, the notes under low and soft; with DEVICES_REAL=1 a frame from a real camera in each sandbox (its light comes on); the probe's report of what each sandbox reaches of this machine's devices (tests/devprobe.zig)
bash tests/shims.sh     # command shims end to end, also for commands installed at run time and GUI programs; Start menu shortcuts; file associations (in a scratch registry key)
bash tests/store.sh     # update, prune, and what they keep while apps run, and for rollback
bash tests/upstream.sh  # scripts/check-upstream.sh with made-up recipes, pages, repositories and OSV answers, and that scripts/upstream.txt covers every recipe's sources (no network; runs on Linux too)
bash tests/rebuild.sh   # scripts/rebuild.sh with made-up recipes and a stand-in zigsaw: its order, pins, stopping and going on (no network; runs on Linux too)
bash tests/build.sh     # building apps: runtimes, images as sources, projects with a zigsaw.json, builds that go on from the last one, build commands on B:, tool caches, aliases, vendor steps, CMake, Meson, Rust, Go, cgo, .NET (WinForms and WPF too), extension points, PHP extensions with zig, reproducibility
GROUP=langs bash tests/build.sh # only one group of its sections (tests/build.sh --groups lists them), as a CI job does
SECTIONS=php bash tests/build.sh # only these sections
bash tests/standard-user.sh account.txt # zigsaw as a real standard user, in an account of its own you've made: the Quick start, your real folders (safe there), a guard's refusal, a store deleted by hand, and the suites that need no app's image
bash scripts/defender-scan.sh # what Defender makes of a package's programs (scripts/package.sh first)
bash tests/gtk.sh       # a GTK and libadwaita app built against GTK's SDK, on its runtime, in each sandbox; the GUI shim, shortcuts and their icons; translations; Text Editor, Rnote and Pinta (C#, on .NET), their file associations, and opening a file with --file; dictionaries and an icon through the runtime's extension point; Gaphor's self-test in each sandbox; GTK with MSVC if the store has it (needs GTK_HOME or BUILD_HOME; opens windows)
bash tests/gtk3.sh      # a GTK 3 app built against GTK 3's SDK and GTK's, on both runtimes, in each sandbox; GTK 3's demos; Gnumeric's ssconvert between CSV, Excel and OpenDocument in each sandbox, its file associations, and opening a file with --file; PyGObject loading GTK 3 and GTK 4, Meld comparing files and folders and showing a git repository's changes in each sandbox, and the published apps all on one build of each GTK runtime (needs GTK_HOME or BUILD_HOME; opens windows)
bash tests/texlive.sh   # TeX Live: pdfLaTeX, XeLaTeX and LuaLaTeX with fonts found by name and formats made on first use in the data directory, BibTeX, MakeIndex, Biber, MetaPost, latexmk on Perl's image, epstopdf and ps2pdf on Ghostscript's, reproducible PDFs, at low integrity too; the AppContainer row is a known gap where Windows hides the drive root (needs TEXLIVE_HOME or BUILD_HOME)
bash tests/postgresql.sh # PostgreSQL's server in each sandbox, its cluster made on first use with a password its clients find; TLS, pgcrypto, ICU collations, lz4 and zstd, XML, PL/Perl and PL/Python and errors raised through them, a dump restored, a zstd backup, pg_ctl stopping it from another run, plperl.on_init, the pgvector, pg_cron and PostGIS extension images joining (an HNSW index, a job every second, a point transformed with PROJ's proj.db, GEOS, GeoJSON, GML, a GiST index and a topology, and PostGIS's rasters on GDAL: values, statistics, a raster reprojected, GeoTIFF and PNG) and --noextension leaving one out; a client outside an AppContainer reaching it through its service (needs POSTGRES_HOME or BUILD_HOME with PostgreSQL and the three extensions)
bash tests/gdal.sh      # GDAL's tools in each sandbox, from the directory they run in: PROJ's proj.db, a GeoTIFF made, read with statistics, warped and turned into a PNG, GeoJSON into a GeoPackage and KML, a clip with GEOS, the gdal command (needs GDAL_HOME or BUILD_HOME)
bash tests/osm2pgsql.sh # osm2pgsql under soft and low, against PostgreSQL's server with PostGIS under soft, from the directory it runs in: the pgsql output with its default style, an update expiring tiles, the flex output with a Lua style requiring a module, from PBF with flat nodes and an area table in UTM, gzip and bzip2 input, -W reading the password, osm2pgsql-expire; and in an AppContainer, reaching the server through its declared port (needs OSM2PGSQL_HOME or BUILD_HOME with osm2pgsql, PostgreSQL and PostGIS)
bash tests/certs.sh     # which apps trust a root CA added to Windows: a test CA made for the run, which each client must refuse until it's in LocalMachine\Root, then trust in each sandbox (Python, Node, Java on the JDK and the JRE, MinGit, CMake, zig, psql, PHP); adding the CA takes an elevated shell, or CERTS_ELEVATE=1 for a UAC prompt (needs CERTS_HOME or BUILD_HOME with Python's image, and the clients' images)
bash tests/qt.sh        # a Qt Widgets app built against Qt's SDK with CMake, on its runtime, in each sandbox: plugins found from the runtime, image formats, Schannel, translations; a Qt Quick window drawn with Direct3D 11 in each sandbox; the SDK's cmake without a recipe; the qml tool; Designer's and Linguist's windows, shims and shortcuts; Flameshot in each sandbox, and its full command saving a screenshot; Notes in each sandbox, its QML and database (needs QT_HOME or BUILD_HOME; opens windows)
bash tests/files.sh     # Files (C#, WinUI 3, on .NET) without a package: its layout, shim and shortcut, starting up, opening a folder, settings kept with its data (needs FILES_HOME or BUILD_HOME; opens windows; local only)
bash tests/guiapps.sh   # 7-Zip, Notepad++, SumatraPDF and VLC in each sandbox: opening a file, where their settings go, shims, shortcuts and file types (opens windows; local only)
bash tests/chromium.sh # ungoogled-chromium, VSCodium and draw.io (on Electron's runtime, with a test app beside it) in each sandbox, with Windows' word on how their processes are confined: pages, WebGL, H.264, a second launch, downloads, a task in VSCodium's terminal with your apps' commands and zigsaw-host, an extension saving a file, a diagram exported from the console, packaged mode, a taskbar button per app, one deployment of the runtime for both; links through the shims and through Windows; shims, shortcuts and what they leave outside, the keys of HKCU's Classes, RegisteredApplications, Clients and Run included
bash tests/zls.sh       # ZLS's language server sessions over stdio in each sandbox: the standard library's documentation, a module a project's build.zig declares, a syntax error; its shim (needs ZLS_HOME or BUILD_HOME, or builds it)
bash tests/php.sh       # PHP's runtime in each sandbox, HTTPS; seven extensions built with php-ext (yaml and zstd with libraries their recipes build) join PHP's runs once installed, and pass their test suites (ssh2 and redis against servers built with Go); an app with two as runtimes, and Xdebug's step debugger; Composer offline; Kanboard's pages and API, in an AppContainer through its service too (needs PHP_HOME or BUILD_HOME; local only)
bash tests/install.sh   # scripts/package.sh's release files, and install.ps1 installing, upgrading and removing zigsaw (in a scratch directory and registry key); `zigsaw upgrade` from a later release of the same code, a running program moved aside and every way of refusing; the daily check in a scratch default store (about 2 min)
bash tests/upgrade.sh   # v0.80.0 and v0.83.0 from GitHub, each with a store of its own (data, a command a run added, a shortcut, a named volume, keys a killed run left in HKCU), upgraded with `zigsaw upgrade` to this checkout's package: everything where this zigsaw keeps it, and still working (RELEASES narrows it; under 1 min)
bash tests/zot.sh bash tests/updates.sh # what a check finds, keeps and tells, and that nothing installs anything; real scheduled tasks under this run's own name, which it removes, and the real one untouched (under 1 min; without a registry, only the task rows)
bash tests/zot.sh bash tests/rollback.sh # the version an update replaces is kept, rollback goes back to it without the network and updates pass over the version left, a newer one gets through, hold and unhold; an install over a version copies the app's data, a rollback asks and takes it back or leaves it, --data-only, while the app runs, a swap that didn't finish, --nosnapshot (under 1 min)
bash tests/zot.sh bash tests/lazy.sh # pull --lazy: placeholders served under each sandbox, a file's chunks in a few requests, a recipe's prefetch files first in the layer and hydrated ahead, a helper that comes back, goes on from what the last one fetched and says what it couldn't fetch, a download that fetches nothing twice, the swap once the download's done and no run uses it, rm, a job that keeps what it starts, a whole download where placeholders can't be, update --lazy copying what the version before has (a source gone, a copy wrong), what runs read written down and asked for ahead of the next version's runs, and a slow fetch telling Windows how far it's got (about 1 min; needs NTFS: LAZY_WORK, and LAZY_DEV_DRIVE for a real Dev Drive row; LAZY_WAIT=90000 for a fetch past Windows' 60 s)
bash tests/zot.sh bash tests/signing.sh # what pull, update and info do with an image's good, wrong and missing signature, with keys `zigsaw trust` adds (under 1 min)
bash tests/self.sh      # zigsaw building this checkout's zigsaw.json makes the same programs as zig build -Dstrip (the Release workflow runs it on its package); an incremental build of a copy after a change makes what --clean does
bash tests/ctrlc.sh     # Ctrl+C, Ctrl+Break and closing the console, in a pseudoconsole
bash tests/batch.sh     # batch files as commands: arguments arrive exactly, and run nothing
bash tests/registry.sh  # push, pull, update, mounts, chunked uploads that break off, multi-platform indexes, logins (zigsaw's and Docker's), sources next to images, the catalog, search and info, through local registries (see its header)
bash tests/oci.sh       # ORAS, skopeo and cosign against local registries, under tests/zot.sh: a file pushed and pulled, an image zigsaw pushed listed, copied to the registry that wants a login and into an OCI layout, signed with a key pair without the internet and verified, each tool's own login; a few runs in an AppContainer (needs OCI_HOME or BUILD_HOME, or builds them)
bash tests/published.sh # fresh builds have the published digests; anonymous pulls, latest, redirects, the catalog
GROUP=java bash tests/published.sh # only one group of scripts/published-groups.txt, as a CI job does
```

The scripts build the recipes they need from [recipes/](recipes/) into
temporary stores unless `ZIGSAW_HOME` points at one. Set `SEED_DOWNLOADS` to
another store's `cache\downloads` and they take the files from there instead
of downloading them. The matrix reports every check whose result differs from
zigsaw's intended behaviour, and fails for those; it also shows the known
gaps below that it runs into, but doesn't fail for them. It first runs a
probe ([`tests/acprobe.zig`](tests/acprobe.zig)) in an AppContainer, and
expects the AppContainer gaps whose causes the probe finds lifted to pass.
The registry tests need a local registry such as
[zot](https://zotregistry.dev) on `localhost:5000`;
[`tests/zot.sh`](tests/zot.sh) starts two, one of them wanting a login. They
are the zot that [`recipes/zot.json`](recipes/zot.json) builds, run by
zigsaw, from the store in `ZOT_HOME` or `BUILD_HOME`; without either, it
builds zot in a temporary store first:

```bash
ZOT_HOME=path/to/a/store/with/zot bash tests/zot.sh bash tests/registry.sh
```

The [Reproduce workflow](.github/workflows/reproduce.yml) runs all of them on
a fresh runner, in a store of the published images the matrix runs and zot
([`tests/seed-store.sh`](tests/seed-store.sh) pulls them, and builds a
version that isn't published yet), as `SEED_DOWNLOADS` and the matrix's
and ZLS's store. The jobs that run `published.sh` check that those images
are what the recipes build. `tests/gtk.sh` and `tests/gtk3.sh` run the
same way, in a job of their own, in a store of GTK's published images and
the apps on them, which they install again rather than build, when GTK's
family is checked; the runner has no GPU, so GTK's OpenGL check is a known
gap there; and it runs Windows Server 2025, where Meld's window in an
AppContainer is one too. `tests/build.sh` runs in
jobs of its own, one for each group of its sections, beside them.
