//! Which keys count for which images and releases. zigsaw-io's own are built in; for
//! other registries, `zigsaw trust` keeps keys in the store, each for a prefix of
//! image names. An image under no prefix has no key, and isn't checked.
//!
//! There's no environment variable for an image's keys. ZIGSAW_UPGRADE_KEY names one
//! for a release, read only alongside ZIGSAW_UPGRADE_FROM, as tests want a release of
//! their own: whoever sets both could as well replace the program.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const signature = @import("signature.zig");
const fail = Context.fail;
const note = Context.note;

/// Where zigsaw-io's images are.
const published_prefix = "ghcr.io/zigsaw-io";

/// zigsaw-io's public keys: the one that signs, and a backup kept offline, for a day
/// when the first is lost or stolen. Both sign images and releases.
const published_keys = [_][]const u8{
    // The one that signs.
    \\-----BEGIN PUBLIC KEY-----
    \\MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUZck4bKpm1+mXkfSwwtKR7F/5wtN
    \\Bv0hEXNn87aFzykUsp9tr5ObOFmfhMYic5jpqF770iN5rpLgiHIfhKrn9Q==
    \\-----END PUBLIC KEY-----
    ,
    // The backup.
    \\-----BEGIN PUBLIC KEY-----
    \\MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEW9tLORn/aGD3/ABpidEgKtLNAclh
    \\MkSEg6LPrxr7b9mkhjFJ3+YTZ00H4tFj87++RLucN6Q8hy1WbefSA30v+w==
    \\-----END PUBLIC KEY-----
    ,
};

pub const Named = struct {
    key: signature.Key,
    prefix: []const u8,
    built_in: bool,
};

/// Whether `repository`, as `<host>/<repository>`, is under `prefix`, by whole path
/// components: ghcr.io/me doesn't reach ghcr.io/menace.
pub fn underPrefix(prefix: []const u8, repository: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, prefix, "/");
    if (trimmed.len == 0 or repository.len < trimmed.len) return false;
    if (!std.ascii.eqlIgnoreCase(repository[0..trimmed.len], trimmed)) return false;
    return repository.len == trimmed.len or repository[trimmed.len] == '/';
}

const Entry = struct { prefix: []const u8, key: []const u8 };
const File = struct { keys: []const Entry = &.{} };

fn path(ctx: *Context) ![]const u8 {
    return ctx.store.path(ctx.arena, &.{"trust.json"});
}

fn read(ctx: *Context) !File {
    const arena = ctx.arena;
    const file = try path(ctx);
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, file, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    return std.json.parseFromSliceLeaky(File, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        fail("{s} isn't what zigsaw wrote: fix or delete it", .{file});
}

fn write(ctx: *Context, entries: []const Entry) !void {
    const file = try path(ctx);
    if (entries.len == 0) {
        Io.Dir.cwd().deleteFile(ctx.io, file) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        return;
    }
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file, .data = try oci.toJson(ctx.arena, File{ .keys = entries }) });
}

/// Every key there is, built-in ones first.
pub fn all(ctx: *Context) ![]const Named {
    const arena = ctx.arena;
    var keys: std.ArrayList(Named) = .empty;
    for (published_keys) |pem| try keys.append(arena, .{
        .key = signature.Key.parse(pem) catch unreachable, // A test sees to that.
        .prefix = published_prefix,
        .built_in = true,
    });
    const file = try read(ctx);
    for (file.keys) |entry| {
        const key = signature.Key.parse(entry.key) catch
            return fail("{s} has a key for {s} that isn't one: `zigsaw trust rm {s}` removes it", .{ try path(ctx), entry.prefix, entry.prefix });
        try keys.append(arena, .{ .key = key, .prefix = entry.prefix, .built_in = false });
    }
    return keys.items;
}

/// The keys that count for an image in `repository`, as `<host>/<repository>`.
pub fn forImage(ctx: *Context, repository: []const u8) ![]const signature.Key {
    const arena = ctx.arena;
    var keys: std.ArrayList(signature.Key) = .empty;
    for (try all(ctx)) |named| if (underPrefix(named.prefix, repository)) try keys.append(arena, named.key);
    return keys.items;
}

/// The keys that count for a release of zigsaw.
pub fn forRelease(ctx: *Context) ![]const signature.Key {
    const arena = ctx.arena;
    var keys: std.ArrayList(signature.Key) = .empty;
    if (ctx.env.get("ZIGSAW_UPGRADE_FROM") != null) if (ctx.env.get("ZIGSAW_UPGRADE_KEY")) |file| {
        const pem = Io.Dir.cwd().readFileAlloc(ctx.io, file, arena, .limited(64 << 10)) catch |err|
            return fail("reading the key {s}: {t}", .{ file, err });
        try keys.append(arena, signature.Key.parse(pem) catch return fail("{s} isn't a P-256 public key", .{file}));
    };
    for (published_keys) |pem| try keys.append(arena, signature.Key.parse(pem) catch unreachable);
    return keys.items;
}

/// `zigsaw trust add <prefix> <key file>`.
pub fn add(ctx: *Context, prefix_arg: []const u8, key_file: []const u8) !void {
    const arena = ctx.arena;
    const prefix = std.mem.trimEnd(u8, prefix_arg, "/");
    if (!isPrefix(prefix)) return fail("\"{s}\" isn't where images are: give a registry and path, like ghcr.io/me or localhost:5000", .{prefix_arg});
    const pem = Io.Dir.cwd().readFileAlloc(ctx.io, key_file, arena, .limited(64 << 10)) catch |err|
        return fail("reading {s}: {t}", .{ key_file, err });
    const key = signature.Key.parse(pem) catch
        return fail("{s} isn't a P-256 public key, as `cosign generate-key-pair` makes in cosign.pub", .{key_file});

    const file = try read(ctx);
    for (file.keys) |entry| if (std.ascii.eqlIgnoreCase(entry.prefix, prefix)) {
        const known = signature.Key.parse(entry.key) catch continue;
        if (std.mem.eql(u8, &known.fingerprint, &key.fingerprint)) {
            note("{s} already has key {s}", .{ prefix, &key.fingerprint });
            return;
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(arena, file.keys);
    try entries.append(arena, .{ .prefix = prefix, .key = pem });
    try write(ctx, entries.items);
    note("images under {s} are now checked against key {s}", .{ prefix, &key.fingerprint });
}

fn isPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    for (prefix) |c| if (c <= ' ' or c == '@' or c == '\\' or c == '"') return false;
    return true;
}

/// `zigsaw trust rm <prefix> [<fingerprint>]`.
pub fn remove(ctx: *Context, prefix_arg: []const u8, fingerprint: ?[]const u8) !void {
    const arena = ctx.arena;
    const prefix = std.mem.trimEnd(u8, prefix_arg, "/");
    const file = try read(ctx);
    var kept: std.ArrayList(Entry) = .empty;
    var removed: usize = 0;
    for (file.keys) |entry| {
        const named = std.ascii.eqlIgnoreCase(entry.prefix, prefix);
        // A key that can't be read can't be named by its fingerprint, so goes either way.
        const same = if (fingerprint) |f| if (signature.Key.parse(entry.key)) |k| std.mem.eql(u8, &k.fingerprint, f) else |_| true else true;
        if (named and same) removed += 1 else try kept.append(arena, entry);
    }
    if (removed == 0) return fail("no key was added for {s}", .{prefix});
    try write(ctx, kept.items);
    note("removed {d} key(s) for {s}", .{ removed, prefix });
}

/// `zigsaw trust`.
pub fn list(ctx: *Context) !void {
    var buf: [4096]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    for (try all(ctx)) |named| try w.print("{s}  key {s}{s}\n", .{ named.prefix, &named.key.fingerprint, if (named.built_in) ", built in" else "" });
    try w.flush();
}

test underPrefix {
    try std.testing.expect(underPrefix("ghcr.io/zigsaw-io", "ghcr.io/zigsaw-io/org.nodejs.node"));
    try std.testing.expect(underPrefix("ghcr.io/zigsaw-io/", "ghcr.io/zigsaw-io/org.nodejs.node"));
    try std.testing.expect(underPrefix("GHCR.io/zigsaw-io", "ghcr.io/zigsaw-io/org.nodejs.node"));
    try std.testing.expect(underPrefix("localhost:5000", "localhost:5000/a/b"));
    try std.testing.expect(underPrefix("ghcr.io/me/app", "ghcr.io/me/app"));
    try std.testing.expect(!underPrefix("ghcr.io/zigsaw-io", "ghcr.io/zigsaw-iox/app"));
    try std.testing.expect(!underPrefix("ghcr.io/zigsaw-io", "ghcr.io/other/app"));
    try std.testing.expect(!underPrefix("ghcr.io/me/app", "ghcr.io/me"));
    try std.testing.expect(!underPrefix("", "ghcr.io/me"));
    try std.testing.expect(!underPrefix("/", "ghcr.io/me"));
}

test "the built-in keys can be read, and there are two different ones" {
    try std.testing.expectEqual(2, published_keys.len);
    const first = try signature.Key.parse(published_keys[0]);
    const second = try signature.Key.parse(published_keys[1]);
    try std.testing.expect(!std.mem.eql(u8, &first.fingerprint, &second.fingerprint));
}
