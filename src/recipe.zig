//! Build recipes: JSON files describing how to assemble an app from pinned
//! sources, the zigsaw equivalent of a flatpak-builder manifest.
//!
//! A recipe is a list of modules, built in order into one prefix that becomes
//! the app's own layer. It names the images it builds with (`sdk`) and the
//! images the app runs with (`runtimes`), each pinned by manifest digest.

const std = @import("std");
const oci = @import("oci.zig");
const Context = @import("Context.zig");
const fail = Context.fail;

pub const Source = struct {
    url: ?[]const u8 = null,
    /// Local file, relative to the recipe.
    path: ?[]const u8 = null,
    /// Required for URLs. A URL without one fails the build and reports the hash to pin.
    sha256: ?[]const u8 = null,
    /// Inferred from the file name when omitted.
    type: ?Kind = null,
    /// For `file`: destination path (default: the source's file name).
    /// For archives: directory to extract into (default: the top).
    dest: ?[]const u8 = null,
    /// For archives: leading directory levels to drop, like `tar --strip-components`.
    strip: u32 = 0,

    pub const Kind = enum {
        file,
        zip,
        tar,
        @"tar.gz",
        @"tar.xz",

        pub fn isArchive(k: Kind) bool {
            return k != .file;
        }
    };

    pub fn location(s: Source) []const u8 {
        return s.url orelse s.path.?;
    }

    /// File name at the end of the URL or path, ignoring any query string.
    pub fn fileName(s: Source) []const u8 {
        const loc = s.location();
        const end = std.mem.indexOfAny(u8, loc, "?#") orelse loc.len;
        const trimmed = loc[0..end];
        const start = if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i| i + 1 else 0;
        return trimmed[start..];
    }

    pub fn kind(s: Source) Kind {
        if (s.type) |k| return k;
        const name = s.fileName();
        const suffixes = [_]struct { []const u8, Kind }{
            .{ ".zip", .zip },
            .{ ".tar", .tar },
            .{ ".tar.gz", .@"tar.gz" },
            .{ ".tgz", .@"tar.gz" },
            .{ ".tar.xz", .@"tar.xz" },
            .{ ".txz", .@"tar.xz" },
        };
        for (suffixes) |entry| if (std.ascii.endsWithIgnoreCase(name, entry[0])) return entry[1];
        return .file;
    }
};

pub const Module = struct {
    /// Names the module in messages and its source directory while building.
    name: []const u8,
    sources: []const Source = &.{},
    /// Commands that build and install the module into $PREFIX, run in order
    /// in its source directory. Without them, the sources go straight into the
    /// prefix.
    build: []const []const u8 = &.{},
    shell: Shell = .sh,
    /// Extra variables for the build commands.
    env: std.json.ArrayHashMap([]const u8) = .{},
    /// Lets the build commands use the network, which the image records.
    network: bool = false,

    pub const Shell = enum { sh, cmd };
};

pub const Recipe = struct {
    id: []const u8,
    version: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    path: []const []const u8 = &.{"."},
    env: std.json.ArrayHashMap([]const u8) = .{},
    permissions: oci.Permissions = .{},
    /// Commands to put on PATH. Without this, the app exports its command
    /// under its file name (e.g. "rg" for rg.exe); `{}` exports nothing.
    exports: ?std.json.ArrayHashMap(oci.Export) = null,
    /// Images the build uses, by alias: references pinned with "@sha256:...".
    sdk: std.json.ArrayHashMap([]const u8) = .{},
    /// Images the app runs with, by alias, pinned the same way. Their
    /// directories are ${<alias>} in the app's config.
    runtimes: std.json.ArrayHashMap([]const u8) = .{},
    /// What to leave out of the app's layer: "/path" from the top of the
    /// prefix, or a file name pattern ("*.pdb") that matches anywhere.
    cleanup: []const []const u8 = &.{},
    /// Toolchains of the machine the build uses: only "msvc" (see msvc.zig).
    /// The image records their versions, and isn't expected to reproduce on
    /// other machines.
    host: []const []const u8 = &.{},
    modules: []const Module,

    /// The app's config, given its resolved runtimes and how it was built.
    pub fn appConfig(
        r: Recipe,
        arena: std.mem.Allocator,
        runtimes: std.json.ArrayHashMap(oci.Runtime),
        build: oci.Build,
    ) !oci.AppConfig {
        var exports: std.json.ArrayHashMap(oci.Export) = .{};
        if (r.exports) |e| {
            exports = e;
        } else {
            try exports.map.put(arena, oci.commandStem(r.command), .{ .command = r.command, .args = r.args });
        }
        return .{
            .id = r.id,
            .version = r.version,
            .command = r.command,
            .args = r.args,
            .path = r.path,
            .env = r.env,
            .permissions = r.permissions,
            .exports = exports,
            .runtimes = runtimes,
            .build = build,
        };
    }

    pub fn hasBuildCommands(r: Recipe) bool {
        for (r.modules) |m| if (m.build.len > 0) return true;
        return false;
    }
};

/// Parses and validates a recipe. `file_name` is only used in messages.
pub fn parse(arena: std.mem.Allocator, file_name: []const u8, bytes: []const u8) !Recipe {
    var scanner: std.json.Scanner = .initCompleteInput(arena, bytes);
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    const r = std.json.parseFromTokenSourceLeaky(Recipe, arena, &scanner, .{}) catch |err| {
        return fail("{s}:{d}:{d}: {t}", .{ file_name, diagnostics.getLine(), diagnostics.getColumn(), err });
    };
    try validateDependencies(file_name, r);
    // The default export is named after the command's file, which for a
    // runtime's command (node.exe) isn't the app's name.
    if (r.exports == null and oci.isPlaceholderPath(r.command) and !std.mem.startsWith(u8, r.command, "${app}"))
        return fail("{s}: the command \"{s}\" is in a runtime, so the recipe must list its \"exports\"", .{ file_name, r.command });
    // The same checks an image pulled from a registry gets, apart from those
    // that need the runtimes resolved.
    try oci.validateEntryPoints(file_name, try r.appConfig(arena, .{}, .{}), r.runtimes.map.keys());
    try validateModules(file_name, r.modules);
    for (r.cleanup) |pattern| if (!isValidCleanupPattern(pattern))
        return fail("{s}: cleanup pattern \"{s}\" must be \"/<path>\" inside the app, or a file name pattern without '/' or '\\'", .{ file_name, pattern });
    for (r.host) |toolchain| if (!std.mem.eql(u8, toolchain, "msvc"))
        return fail("{s}: host toolchain \"{s}\" isn't one zigsaw knows; only \"msvc\" is", .{ file_name, toolchain });
    if (r.host.len > 0 and !r.hasBuildCommands())
        return fail("{s}: \"host\" toolchains are for build commands, and no module has any", .{file_name});
    return r;
}

fn validateDependencies(file_name: []const u8, r: Recipe) error{Failed}!void {
    for ([_]struct { []const u8, std.json.ArrayHashMap([]const u8) }{ .{ "sdk", r.sdk }, .{ "runtimes", r.runtimes } }) |group| {
        const what, const deps = group;
        for (deps.map.keys()) |alias| {
            if (!oci.isValidAlias(alias))
                return fail("{s}: {s} alias \"{s}\" must be lowercase letters, digits, '-' or '_', start with a letter, and not be app or data", .{ file_name, what, alias });
        }
    }
    // Both kinds are on PATH while building, so one alias means one image.
    for (r.sdk.map.keys()) |alias| if (r.runtimes.map.contains(alias))
        return fail("{s}: \"{s}\" is both an sdk and a runtime alias", .{ file_name, alias });
}

fn validateModules(file_name: []const u8, modules: []const Module) error{Failed}!void {
    if (modules.len == 0)
        return fail("{s}: at least one module is required", .{file_name});
    for (modules, 0..) |m, i| {
        if (!oci.isValidId(m.name))
            return fail("{s}: module name \"{s}\" must be 1-57 characters of letters, digits, '.', '-', '_'", .{ file_name, m.name });
        for (modules[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, m.name))
            return fail("{s}: there are two modules named {s}", .{ file_name, m.name });
        if (m.sources.len == 0 and m.build.len == 0)
            return fail("{s}: module {s} has neither sources nor build commands", .{ file_name, m.name });
        if (m.build.len == 0 and (m.network or m.env.map.count() > 0))
            return fail("{s}: module {s} sets \"network\" or \"env\", which only apply to build commands", .{ file_name, m.name });
        for (m.sources, 1..) |s, n| try validateSource(file_name, m.name, n, s);
    }
}

fn validateSource(file_name: []const u8, module: []const u8, n: usize, s: Source) error{Failed}!void {
    if ((s.url == null) == (s.path == null))
        return fail("{s}: module {s} source {d} needs exactly one of \"url\" or \"path\"", .{ file_name, module, n });
    if (s.sha256) |h| if (!oci.isSha256Hex(h))
        return fail("{s}: module {s} source {d} sha256 must be 64 lowercase hex characters", .{ file_name, module, n });
    if (s.dest) |d| if (!oci.isSafeRelPath(d))
        return fail("{s}: module {s} source {d} dest \"{s}\" must be a relative path inside the app", .{ file_name, module, n, d });
    if (s.strip != 0 and !s.kind().isArchive())
        return fail("{s}: module {s} source {d} uses \"strip\", which only applies to archives", .{ file_name, module, n });
    if (s.kind() == .file and s.dest == null and s.fileName().len == 0)
        return fail("{s}: module {s} source {d} has no file name; set \"dest\"", .{ file_name, module, n });
}

fn isValidCleanupPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '/') return oci.isSafeRelPath(pattern[1..]);
    return std.mem.indexOfAny(u8, pattern, "/\\:") == null;
}

/// Whether `cleanup` removes the entry at `path` ('/'-separated, from the
/// top of the prefix): a "/<path>" pattern names it or one of its parents,
/// and a file name pattern matches one of its components.
pub fn cleanupMatches(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (pattern[0] == '/') {
            const want = std.mem.trim(u8, pattern, "/");
            if (startsWithComponents(path, want)) return true;
        } else {
            var parts = std.mem.splitScalar(u8, path, '/');
            while (parts.next()) |part| if (globMatch(pattern, part)) return true;
        }
    }
    return false;
}

/// Whether `path` is `prefix` or below it, case-insensitively, comparing
/// whole components: "a/b" is below "a", and "ab" isn't.
fn startsWithComponents(path: []const u8, prefix: []const u8) bool {
    var want = std.mem.tokenizeAny(u8, prefix, "/\\");
    var have = std.mem.splitScalar(u8, path, '/');
    while (want.next()) |w| {
        const h = have.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(w, h)) return false;
    }
    return true;
}

/// Matches a file name against a pattern with `*` (any run of characters)
/// and `?` (one character), ignoring case, as Windows file names do.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    // Where to resume after the last '*': its position in the pattern, and
    // how much of the name it covers so far.
    var star: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n]))) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "parse minimal recipe" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const r = try parse(arena_state.allocator(), "test.json",
        \\{
        \\  "id": "net.frippery.busybox",
        \\  "version": "1",
        \\  "command": "busybox.exe",
        \\  "modules": [{ "name": "busybox", "sources": [{ "url": "https://example.com/bb.exe?x=1", "dest": "busybox.exe" }] }]
        \\}
    );
    try std.testing.expectEqualStrings("busybox.exe", r.command);
    const src = r.modules[0].sources[0];
    try std.testing.expectEqual(Source.Kind.file, src.kind());
    try std.testing.expectEqualStrings("bb.exe", src.fileName());
    try std.testing.expectEqual(false, r.permissions.network);
    try std.testing.expect(!r.hasBuildCommands());

    const cfg = try r.appConfig(arena_state.allocator(), .{}, .{});
    try std.testing.expectEqual(1, cfg.exports.map.count());
    try std.testing.expectEqualStrings("busybox.exe", cfg.exports.map.get("busybox").?.command);
}

test "recipe checks" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = try parse(arena, "t.json",
        \\{ "id": "x.tsc", "version": "1", "command": "${node}\\node.exe", "args": ["${app}\\tsc.js"],
        \\  "runtimes": { "node": "org.nodejs.node@sha256:0000000000000000000000000000000000000000000000000000000000000000" },
        \\  "exports": { "tsc": { "command": "${node}\\node.exe", "args": ["${app}\\tsc.js"] } },
        \\  "cleanup": ["/include", "*.pdb"],
        \\  "modules": [{ "name": "tsc", "sources": [{ "path": "tsc.tgz", "strip": 1 }] }] }
    );
    try std.testing.expectEqual(Source.Kind.@"tar.gz", ok.modules[0].sources[0].kind());

    const bad = [_][]const u8{
        // A command in a runtime needs exports.
        \\{ "id": "x", "version": "1", "command": "${node}\\node.exe", "runtimes": { "node": "n" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        // An unknown alias.
        \\{ "id": "x", "version": "1", "command": "${node}\\node.exe", "exports": {}, "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        // A reserved alias.
        \\{ "id": "x", "version": "1", "command": "a.exe", "runtimes": { "data": "d" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        // The same alias twice.
        \\{ "id": "x", "version": "1", "command": "a.exe", "sdk": { "zig": "z" }, "runtimes": { "zig": "z" }, "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        // No modules, or an empty one.
        \\{ "id": "x", "version": "1", "command": "a.exe", "modules": [] }
        ,
        \\{ "id": "x", "version": "1", "command": "a.exe", "modules": [{ "name": "m" }] }
        ,
        // Two modules with one name.
        \\{ "id": "x", "version": "1", "command": "a.exe", "modules": [{ "name": "m", "build": ["x"] }, { "name": "M", "build": ["y"] }] }
        ,
        // Network for a module that builds nothing.
        \\{ "id": "x", "version": "1", "command": "a.exe", "modules": [{ "name": "m", "network": true, "sources": [{ "path": "a.exe" }] }] }
        ,
        // strip on a file.
        \\{ "id": "x", "version": "1", "command": "a.exe", "modules": [{ "name": "m", "sources": [{ "path": "a.exe", "strip": 1 }] }] }
        ,
        // Cleanup patterns.
        \\{ "id": "x", "version": "1", "command": "a.exe", "cleanup": ["/../x"], "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        \\{ "id": "x", "version": "1", "command": "a.exe", "cleanup": ["lib/*.a"], "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        // Host toolchains: only msvc, and only for build commands.
        \\{ "id": "x", "version": "1", "command": "a.exe", "host": ["gcc"], "modules": [{ "name": "m", "build": ["x"] }] }
        ,
        \\{ "id": "x", "version": "1", "command": "a.exe", "host": ["msvc"], "modules": [{ "name": "m", "sources": [{ "path": "a.exe" }] }] }
        ,
    };
    for (bad) |text| try std.testing.expectError(error.Failed, parse(arena, "t.json", text));
}

test "archive kinds are inferred" {
    const cases = [_]struct { []const u8, Source.Kind }{
        .{ "https://example.com/node-v22-win-x64.ZIP", .zip },
        .{ "https://registry.npmjs.org/prettier/-/prettier-3.9.9.tgz", .@"tar.gz" },
        .{ "zlib-1.3.1.tar.gz", .@"tar.gz" },
        .{ "x.tar.xz", .@"tar.xz" },
        .{ "x.tar", .tar },
        .{ "tool.exe", .file },
    };
    for (cases) |c| {
        const s: Source = .{ .url = c[0] };
        try std.testing.expectEqual(c[1], s.kind());
    }
}

test cleanupMatches {
    const patterns: []const []const u8 = &.{ "/include", "/lib/pkgconfig", "*.pdb", "__pycache__" };
    try std.testing.expect(cleanupMatches(patterns, "include"));
    try std.testing.expect(cleanupMatches(patterns, "Include/zlib.h"));
    try std.testing.expect(!cleanupMatches(patterns, "includes/x.h"));
    try std.testing.expect(cleanupMatches(patterns, "lib/pkgconfig/zlib.pc"));
    try std.testing.expect(!cleanupMatches(patterns, "lib/libz.a"));
    try std.testing.expect(cleanupMatches(patterns, "bin/sqlite3.PDB"));
    try std.testing.expect(cleanupMatches(patterns, "lib/x/__pycache__/a.pyc"));
    try std.testing.expect(!cleanupMatches(patterns, "bin/sqlite3.exe"));
}

test globMatch {
    try std.testing.expect(globMatch("*.a", "libz.a"));
    try std.testing.expect(!globMatch("*.a", "libz.a.txt"));
    try std.testing.expect(globMatch("lib*.dll", "LIBZ.DLL"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("a?c", "ac"));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(globMatch("*x*y*", "axbyc"));
    try std.testing.expect(!globMatch("*x*y", "axbyc"));
}
