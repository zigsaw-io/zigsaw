//! `.gitignore` patterns, read and matched as git reads and matches them, so
//! that a project's build gets the files git would commit, and not what its
//! tools leave in its directory (zig-out, target, node_modules).
//!
//! Matching ignores case, as git does on Windows (core.ignorecase). Only the
//! project's own `.gitignore` files count, not the global excludes or
//! `.git/info/exclude` of the machine it's on, so the same checkout gives the
//! same files everywhere (see project.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pattern = struct {
    /// What's matched, without a leading '!', a leading '/' or a trailing '/'.
    glob: []const u8,
    /// A leading '!': a path it matches is kept after all.
    negate: bool = false,
    /// A trailing '/': it matches directories only.
    dir_only: bool = false,
    /// A '/' at the start or in the middle: it's matched against the path
    /// from the `.gitignore`'s directory, rather than against a name at any
    /// depth below it.
    anchored: bool = false,

    /// Whether it matches the entry at `rel`, '/'-separated, from the
    /// `.gitignore`'s directory.
    pub fn matches(p: Pattern, rel: []const u8, is_dir: bool) bool {
        if (p.dir_only and !is_dir) return false;
        if (p.anchored) return wildmatch(p.glob, rel);
        const name = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
        return wildmatch(p.glob, name);
    }
};

/// The patterns of a `.gitignore` file, in order.
pub fn parse(arena: Allocator, bytes: []const u8) ![]const Pattern {
    var patterns: std.ArrayList(Pattern) = .empty;
    const text = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = trimTrailingSpaces(std.mem.trimEnd(u8, raw, "\r"));
        if (line.len == 0 or line[0] == '#') continue;
        var p: Pattern = .{ .glob = "" };
        if (line[0] == '!') {
            p.negate = true;
            line = line[1..];
        }
        if (std.mem.endsWith(u8, line, "/")) {
            p.dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (std.mem.indexOfScalar(u8, line, '/')) |i| {
            p.anchored = true;
            if (i == 0) line = line[1..];
        }
        if (line.len == 0) continue;
        p.glob = line;
        try patterns.append(arena, p);
    }
    return patterns.items;
}

/// Drops trailing spaces, but not one escaped with a backslash.
fn trimTrailingSpaces(line: []const u8) []const u8 {
    var end: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) switch (line[i]) {
        ' ' => {
            if (end == null) end = i;
        },
        '\\' => {
            i += 1;
            end = null;
        },
        else => end = null,
    };
    return line[0 .. end orelse line.len];
}

/// The patterns that apply below a directory: those of the `.gitignore`
/// files from the top of the repository down to it, nearest last.
pub const Rules = struct {
    levels: std.ArrayList(Level) = .empty,

    pub const Level = struct {
        /// The `.gitignore`'s directory, '/'-separated, from the top of the
        /// repository ("" for the top).
        base: []const u8,
        patterns: []const Pattern,
    };

    pub fn push(r: *Rules, arena: Allocator, base: []const u8, patterns: []const Pattern) !void {
        try r.levels.append(arena, .{ .base = base, .patterns = patterns });
    }

    pub fn pop(r: *Rules) void {
        _ = r.levels.pop();
    }

    /// Whether git ignores the entry at `path` ('/'-separated, from the top
    /// of the repository): as git decides, the last pattern that matches it
    /// in the nearest `.gitignore` that has one.
    pub fn ignored(r: Rules, path: []const u8, is_dir: bool) bool {
        var i = r.levels.items.len;
        while (i > 0) {
            i -= 1;
            const level = r.levels.items[i];
            const rel = below(path, level.base) orelse continue;
            var j = level.patterns.len;
            while (j > 0) {
                j -= 1;
                const p = level.patterns[j];
                if (p.matches(rel, is_dir)) return !p.negate;
            }
        }
        return false;
    }

    /// `path` from `base`, if it's below it.
    fn below(path: []const u8, base: []const u8) ?[]const u8 {
        if (base.len == 0) return path;
        if (path.len <= base.len or path[base.len] != '/' or !std.ascii.eqlIgnoreCase(path[0..base.len], base)) return null;
        return path[base.len + 1 ..];
    }
};

/// Matches a '/'-separated path against a pattern as git's wildmatch does
/// with WM_PATHNAME and WM_CASEFOLD: `*`, `?` and `[...]` don't match '/',
/// `**` as a whole component matches any number of directories, and a
/// backslash escapes the character after it.
pub fn wildmatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    while (p < pattern.len) switch (pattern[p]) {
        '*' => {
            var end = p;
            while (end < pattern.len and pattern[end] == '*') end += 1;
            const rest = pattern[end..];
            if (end - p >= 2 and (p == 0 or pattern[p - 1] == '/') and (rest.len == 0 or rest[0] == '/')) {
                // "**" at the end matches everything below; "**/" matches
                // zero or more directories.
                if (rest.len == 0) return true;
                var k = t;
                while (true) {
                    if (wildmatch(rest[1..], text[k..])) return true;
                    k = (std.mem.indexOfScalarPos(u8, text, k, '/') orelse return false) + 1;
                }
            }
            // Otherwise any run of characters within one component.
            var k = t;
            while (true) {
                if (wildmatch(rest, text[k..])) return true;
                if (k == text.len or text[k] == '/') return false;
                k += 1;
            }
        },
        '?' => {
            if (t == text.len or text[t] == '/') return false;
            p += 1;
            t += 1;
        },
        '[' => {
            if (t == text.len or text[t] == '/') return false;
            const class = matchClass(pattern[p..], text[t]) orelse return false;
            if (!class.matched) return false;
            p += class.len;
            t += 1;
        },
        else => |c| {
            var want = c;
            if (c == '\\' and p + 1 < pattern.len) {
                p += 1;
                want = pattern[p];
            }
            if (t == text.len or std.ascii.toLower(text[t]) != std.ascii.toLower(want)) return false;
            p += 1;
            t += 1;
        },
    };
    return t == text.len;
}

/// Matches `c` against the class at the start of `pattern` ("[a-z]",
/// "[!.]", "[[:digit:]]"). Null if the class has no closing ']', which git
/// takes as a pattern that matches nothing.
fn matchClass(pattern: []const u8, c: u8) ?struct { matched: bool, len: usize } {
    var i: usize = 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    const first = i;
    while (i < pattern.len) {
        var lo = pattern[i];
        // A ']' first is part of the class.
        if (lo == ']' and i > first) return .{ .matched = matched != negate, .len = i + 1 };
        if (lo == '[' and i + 1 < pattern.len and pattern[i + 1] == ':') {
            const close = std.mem.indexOfPos(u8, pattern, i + 2, ":]") orelse return null;
            if (posixClass(pattern[i + 2 .. close], c)) matched = true;
            i = close + 2;
            continue;
        }
        if (lo == '\\') {
            i += 1;
            if (i == pattern.len) return null;
            lo = pattern[i];
        }
        i += 1;
        if (i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']') {
            var hi = pattern[i + 1];
            i += 2;
            if (hi == '\\') {
                if (i == pattern.len) return null;
                hi = pattern[i];
                i += 1;
            }
            const lower = std.ascii.toLower(c);
            const upper = std.ascii.toUpper(c);
            if ((c >= lo and c <= hi) or (lower >= lo and lower <= hi) or (upper >= lo and upper <= hi)) matched = true;
        } else if (std.ascii.toLower(c) == std.ascii.toLower(lo)) matched = true;
    }
    return null;
}

fn posixClass(name: []const u8, c: u8) bool {
    const classes = [_]struct { []const u8, *const fn (u8) bool }{
        .{ "alnum", std.ascii.isAlphanumeric },
        .{ "alpha", std.ascii.isAlphabetic },
        .{ "blank", isBlank },
        .{ "cntrl", std.ascii.isControl },
        .{ "digit", std.ascii.isDigit },
        .{ "graph", isGraph },
        // Case doesn't count, so either case is a letter of both.
        .{ "lower", std.ascii.isAlphabetic },
        .{ "print", std.ascii.isPrint },
        .{ "punct", isPunct },
        .{ "space", std.ascii.isWhitespace },
        .{ "upper", std.ascii.isAlphabetic },
        .{ "xdigit", std.ascii.isHex },
    };
    for (classes) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1](c);
    return false;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isGraph(c: u8) bool {
    return std.ascii.isPrint(c) and c != ' ';
}

fn isPunct(c: u8) bool {
    return isGraph(c) and !std.ascii.isAlphanumeric(c);
}

test wildmatch {
    const yes = [_][2][]const u8{
        .{ "*.o", "main.o" },
        .{ "*.O", "main.o" },
        .{ "a?c", "abc" },
        .{ "[a-c]x", "bx" },
        .{ "[a-c]x", "Bx" },
        .{ "[!.]x", "ax" },
        .{ "[^.]x", "ax" },
        .{ "[]]", "]" },
        .{ "[[:digit:]]*", "7z" },
        .{ "\\*", "*" },
        .{ "\\#x", "#x" },
        .{ "foo\\ ", "foo " },
        .{ "**/foo", "foo" },
        .{ "**/foo", "a/b/foo" },
        .{ "**/foo/bar", "x/foo/bar" },
        .{ "abc/**", "abc/x/y" },
        .{ "a/**/b", "a/b" },
        .{ "a/**/b", "a/x/y/b" },
        .{ "doc/*.txt", "doc/notes.txt" },
        .{ "foo**bar", "fooxbar" },
        .{ "*", "" },
    };
    for (yes) |c| std.testing.expect(wildmatch(c[0], c[1])) catch |err| {
        std.debug.print("{s} should match {s}\n", .{ c[0], c[1] });
        return err;
    };
    const no = [_][2][]const u8{
        .{ "*.o", "main.c" },
        .{ "a?c", "a/c" },
        .{ "*", "a/b" },
        .{ "doc/*.txt", "doc/x/notes.txt" },
        .{ "[a-c]x", "dx" },
        .{ "[!.]x", ".x" },
        .{ "[a-c", "a" },
        .{ "abc/**", "abc" },
        .{ "a/**/b", "a/xb" },
        .{ "foo**bar", "foo/bar" },
        .{ "**/foo", "foox" },
    };
    for (no) |c| std.testing.expect(!wildmatch(c[0], c[1])) catch |err| {
        std.debug.print("{s} shouldn't match {s}\n", .{ c[0], c[1] });
        return err;
    };
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const patterns = try parse(arena_state.allocator(), "\xEF\xBB\xBF# comment\r\n\nzig-out/\r\n/top.txt\n!keep.log  \ndoc/frotz/\n\\#hash\nspace\\ \n/\n");
    try std.testing.expectEqual(6, patterns.len);
    try std.testing.expectEqualDeep(Pattern{ .glob = "zig-out", .dir_only = true }, patterns[0]);
    try std.testing.expectEqualDeep(Pattern{ .glob = "top.txt", .anchored = true }, patterns[1]);
    try std.testing.expectEqualDeep(Pattern{ .glob = "keep.log", .negate = true }, patterns[2]);
    try std.testing.expectEqualDeep(Pattern{ .glob = "doc/frotz", .dir_only = true, .anchored = true }, patterns[3]);
    try std.testing.expectEqualDeep(Pattern{ .glob = "\\#hash" }, patterns[4]);
    try std.testing.expectEqualDeep(Pattern{ .glob = "space\\ " }, patterns[5]);
}

test Rules {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rules: Rules = .{};
    try rules.push(arena, "", try parse(arena, "*.log\n!keep.log\nout/\n/top.txt\ndocs/**/draft.md\n"));
    try rules.push(arena, "sub", try parse(arena, "!again.log\nlocal.txt\n/anchored.txt\n"));

    try std.testing.expect(rules.ignored("a.log", false));
    try std.testing.expect(rules.ignored("x/a.LOG", false));
    try std.testing.expect(!rules.ignored("keep.log", false));
    try std.testing.expect(rules.ignored("out", true));
    try std.testing.expect(rules.ignored("x/out", true));
    // A trailing '/' is for directories only.
    try std.testing.expect(!rules.ignored("out", false));
    try std.testing.expect(rules.ignored("top.txt", false));
    try std.testing.expect(!rules.ignored("x/top.txt", false));
    try std.testing.expect(rules.ignored("docs/draft.md", false));
    try std.testing.expect(rules.ignored("docs/a/b/draft.md", false));
    // The nearer .gitignore decides: sub's re-includes, ignores, and anchors
    // at sub.
    try std.testing.expect(!rules.ignored("sub/again.log", false));
    try std.testing.expect(rules.ignored("sub/x/local.txt", false));
    try std.testing.expect(!rules.ignored("local.txt", false));
    try std.testing.expect(rules.ignored("Sub/anchored.txt", false));
    try std.testing.expect(!rules.ignored("sub/x/anchored.txt", false));
    rules.pop();
    try std.testing.expect(rules.ignored("sub/again.log", false));
}
