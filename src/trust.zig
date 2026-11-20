//! Whose signatures count for which images and releases: a key's, or, keyless, a
//! certificate's that Sigstore vouches for, naming who signed (a workflow, say).
//! zigsaw-io's own are built in; for other registries, the store keeps them in
//! trust.json, each for a prefix of image names: a remote's location, as
//! `zigsaw remote-modify --sign-key` and `--keyless` add them (see remotes.zig).
//! An image under no prefix has nobody's, and isn't checked.
//!
//! There's no environment variable for an image's signers. ZIGSAW_UPGRADE_KEY names a
//! key for a release, read only alongside ZIGSAW_UPGRADE_FROM, as tests want a release
//! of their own: whoever sets both could as well replace the program.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const signature = @import("signature.zig");
const sigstore = @import("sigstore.zig");
const fail = Context.fail;
const note = Context.note;

/// Where zigsaw-io's images are.
const published_prefix = "ghcr.io/zigsaw-io";

/// zigsaw-io's public keys, from before signing went keyless (iteration 81): the one
/// that signed, and a backup kept offline. Images they signed stay good. Of releases,
/// only the backup's count: it's how a release reaches a zigsaw that can no longer
/// check Sigstore's signatures, should Sigstore's root change past what it knows.
const published_keys = [_][]const u8{
    // The one that signed, up to v0.81.0's release.
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
const backup_key = 1;

/// Who signs zigsaw-io's images: the Reproduce workflow, on main, right after it
/// rebuilt each from its recipe and got the registry's digest.
const published_image_identity: sigstore.Identity = .{
    .issuer = sigstore.github_issuer,
    .san = "https://github.com/zigsaw-io/zigsaw/.github/workflows/reproduce.yml@refs/heads/main",
};
/// Who signs a release: the Release workflow, run for the release's own tag.
const release_workflow = "https://github.com/zigsaw-io/zigsaw/.github/workflows/release.yml";

/// One whose signature counts.
pub const Signer = union(enum) {
    key: signature.Key,
    keyless: sigstore.Identity,

    /// "key <fingerprint>", or the identity a certificate must name.
    pub fn format(s: Signer, w: *Io.Writer) Io.Writer.Error!void {
        switch (s) {
            .key => |k| try w.print("key {s}", .{&k.fingerprint}),
            .keyless => |id| if (std.mem.eql(u8, id.issuer, sigstore.github_issuer))
                try w.writeAll(id.san)
            else
                try w.print("{s}, as {s} says", .{ id.san, id.issuer }),
        }
    }
};

pub const Named = struct {
    signer: Signer,
    prefix: []const u8,
    built_in: bool,
};

/// The identity a release of `version` must be signed by.
pub fn releaseIdentity(arena: Allocator, version: []const u8) !sigstore.Identity {
    return .{ .issuer = sigstore.github_issuer, .san = try std.fmt.allocPrint(arena, "{s}@refs/tags/v{s}", .{ release_workflow, version }) };
}

/// Whether `repository`, as `<host>/<repository>`, is under `prefix`, by whole path
/// components: ghcr.io/me doesn't reach ghcr.io/menace.
pub fn underPrefix(prefix: []const u8, repository: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, prefix, "/");
    if (trimmed.len == 0 or repository.len < trimmed.len) return false;
    if (!std.ascii.eqlIgnoreCase(repository[0..trimmed.len], trimmed)) return false;
    return repository.len == trimmed.len or repository[trimmed.len] == '/';
}

const Entry = struct { prefix: []const u8, key: []const u8 };
/// Keyless ones are a list of their own, which a zigsaw from before them skips.
const KeylessEntry = struct { prefix: []const u8, san: []const u8, issuer: []const u8 };
const File = struct { keys: []const Entry = &.{}, keyless: []const KeylessEntry = &.{} };

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

fn write(ctx: *Context, file: File) !void {
    const p = try path(ctx);
    if (file.keys.len == 0 and file.keyless.len == 0) {
        Io.Dir.cwd().deleteFile(ctx.io, p) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        return;
    }
    // Written as one with no keyless list was, when it has none.
    const data = if (file.keyless.len == 0)
        try oci.toJson(ctx.arena, struct { keys: []const Entry }{ .keys = file.keys })
    else
        try oci.toJson(ctx.arena, file);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = data });
}

/// Everyone whose signatures count for images, built-in ones first.
pub fn all(ctx: *Context) ![]const Named {
    const arena = ctx.arena;
    var signers: std.ArrayList(Named) = .empty;
    try signers.append(arena, .{ .signer = .{ .keyless = published_image_identity }, .prefix = published_prefix, .built_in = true });
    for (published_keys) |pem| try signers.append(arena, .{
        .signer = .{ .key = signature.Key.parse(pem) catch unreachable }, // A test sees to that.
        .prefix = published_prefix,
        .built_in = true,
    });
    const file = try read(ctx);
    for (file.keys) |entry| {
        const key = signature.Key.parse(entry.key) catch
            return fail("{s} has a key for {s} that isn't one: `zigsaw remote-modify --no-sign-key <remote>` removes it, for the remote at {s}", .{ try path(ctx), entry.prefix, entry.prefix });
        try signers.append(arena, .{ .signer = .{ .key = key }, .prefix = entry.prefix, .built_in = false });
    }
    for (file.keyless) |entry|
        try signers.append(arena, .{ .signer = .{ .keyless = .{ .san = entry.san, .issuer = entry.issuer } }, .prefix = entry.prefix, .built_in = false });
    return signers.items;
}

/// Those whose signatures count for an image in `repository`, as
/// `<host>/<repository>`.
pub fn forImage(ctx: *Context, repository: []const u8) ![]const Signer {
    const arena = ctx.arena;
    var signers: std.ArrayList(Signer) = .empty;
    for (try all(ctx)) |named| if (underPrefix(named.prefix, repository)) try signers.append(arena, named.signer);
    return signers.items;
}

/// Those whose signatures count for zigsaw's release of `version`.
pub fn forRelease(ctx: *Context, version: []const u8) ![]const Signer {
    const arena = ctx.arena;
    var signers: std.ArrayList(Signer) = .empty;
    try signers.append(arena, .{ .keyless = try releaseIdentity(arena, version) });
    if (ctx.env.get("ZIGSAW_UPGRADE_FROM") != null) if (ctx.env.get("ZIGSAW_UPGRADE_KEY")) |file| {
        const pem = Io.Dir.cwd().readFileAlloc(ctx.io, file, arena, .limited(64 << 10)) catch |err|
            return fail("reading the key {s}: {t}", .{ file, err });
        try signers.append(arena, .{ .key = signature.Key.parse(pem) catch return fail("{s} isn't a P-256 public key", .{file}) });
    };
    try signers.append(arena, .{ .key = signature.Key.parse(published_keys[backup_key]) catch unreachable });
    return signers.items;
}

/// The prefixes trust.json has signers for: places `zigsaw trust add` named
/// before remotes, and remotes' locations since.
pub fn addedPrefixes(ctx: *Context) ![]const []const u8 {
    const arena = ctx.arena;
    const file = try read(ctx);
    var out: std.ArrayList([]const u8) = .empty;
    for (file.keys) |e| try appendNew(arena, &out, e.prefix);
    for (file.keyless) |e| try appendNew(arena, &out, e.prefix);
    return out.items;
}

fn appendNew(arena: Allocator, list: *std.ArrayList([]const u8), prefix: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, prefix, "/");
    for (list.items) |p| if (std.ascii.eqlIgnoreCase(p, trimmed)) return;
    try list.append(arena, trimmed);
}

/// Has the signers added for `old` count for `new` instead, as a remote
/// moves; returns how many.
pub fn movePrefix(ctx: *Context, old: []const u8, new: []const u8) !usize {
    const arena = ctx.arena;
    const file = try read(ctx);
    const keys = try arena.dupe(Entry, file.keys);
    const keyless = try arena.dupe(KeylessEntry, file.keyless);
    var moved: usize = 0;
    for (keys) |*e| if (samePrefix(e.prefix, old)) {
        e.prefix = new;
        moved += 1;
    };
    for (keyless) |*e| if (samePrefix(e.prefix, old)) {
        e.prefix = new;
        moved += 1;
    };
    if (moved > 0) try write(ctx, .{ .keys = keys, .keyless = keyless });
    return moved;
}

/// Removes the signers added for `prefix`, saying nothing, as a remote goes;
/// returns how many.
pub fn removeAll(ctx: *Context, prefix: []const u8) !usize {
    const arena = ctx.arena;
    const file = try read(ctx);
    var keys: std.ArrayList(Entry) = .empty;
    var keyless: std.ArrayList(KeylessEntry) = .empty;
    for (file.keys) |e| if (!samePrefix(e.prefix, prefix)) try keys.append(arena, e);
    for (file.keyless) |e| if (!samePrefix(e.prefix, prefix)) try keyless.append(arena, e);
    const removed = file.keys.len + file.keyless.len - keys.items.len - keyless.items.len;
    if (removed > 0) try write(ctx, .{ .keys = keys.items, .keyless = keyless.items });
    return removed;
}

fn samePrefix(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

/// `zigsaw remote-modify --sign-key=<key file>`, for the remote's location.
pub fn add(ctx: *Context, prefix_arg: []const u8, key_file: []const u8) !void {
    const arena = ctx.arena;
    const prefix = try checkPrefix(prefix_arg);
    const pem, const key = try readKey(ctx, key_file);

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
    try write(ctx, .{ .keys = entries.items, .keyless = file.keyless });
    note("images under {s} are now checked against key {s}", .{ prefix, &key.fingerprint });
}

/// `zigsaw remote-modify --keyless=<identity> [--issuer=<url>]`.
pub fn addKeyless(ctx: *Context, prefix_arg: []const u8, san: []const u8, issuer: []const u8) !void {
    const arena = ctx.arena;
    const prefix = try checkPrefix(prefix_arg);
    try checkKeyless(san, issuer);

    const file = try read(ctx);
    const signer: Signer = .{ .keyless = .{ .san = san, .issuer = issuer } };
    for (file.keyless) |entry| if (std.ascii.eqlIgnoreCase(entry.prefix, prefix) and std.mem.eql(u8, entry.san, san) and std.mem.eql(u8, entry.issuer, issuer)) {
        note("{s} already has {f}", .{ prefix, signer });
        return;
    };
    var entries: std.ArrayList(KeylessEntry) = .empty;
    try entries.appendSlice(arena, file.keyless);
    try entries.append(arena, .{ .prefix = prefix, .san = san, .issuer = issuer });
    try write(ctx, .{ .keys = file.keys, .keyless = entries.items });
    note("images under {s} are now checked against {f}, keyless", .{ prefix, signer });
}

/// Fails as `add` and `addKeyless` would, unless every key file holds a key
/// and the keyless identity and issuer can be one; changes nothing.
pub fn check(ctx: *Context, key_files: []const []const u8, san: ?[]const u8, issuer: []const u8) !void {
    for (key_files) |f| _ = try readKey(ctx, f);
    if (san) |id| try checkKeyless(id, issuer);
}

fn readKey(ctx: *Context, key_file: []const u8) !struct { []const u8, signature.Key } {
    const pem = Io.Dir.cwd().readFileAlloc(ctx.io, key_file, ctx.arena, .limited(64 << 10)) catch |err|
        return fail("reading {s}: {t}", .{ key_file, err });
    const key = signature.Key.parse(pem) catch
        return fail("{s} isn't a P-256 public key, as `cosign generate-key-pair` makes in cosign.pub", .{key_file});
    return .{ pem, key };
}

fn checkKeyless(san: []const u8, issuer: []const u8) !void {
    if (san.len == 0 or std.mem.indexOfAny(u8, san, " \t\r\n\"") != null)
        return fail("\"{s}\" isn't an identity: give what the certificate names, like https://github.com/me/app/.github/workflows/release.yml@refs/heads/main", .{san});
    if (!std.mem.startsWith(u8, issuer, "https://")) return fail("\"{s}\" isn't an issuer: give its URL, like {s}", .{ issuer, sigstore.github_issuer });
}

fn checkPrefix(prefix_arg: []const u8) ![]const u8 {
    const prefix = std.mem.trimEnd(u8, prefix_arg, "/");
    if (!isPrefix(prefix)) return fail("\"{s}\" isn't where images are: give a registry and path, like ghcr.io/me or localhost:5000", .{prefix_arg});
    return prefix;
}

fn isPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    for (prefix) |c| if (c <= ' ' or c == '@' or c == '\\' or c == '"') return false;
    return true;
}

/// `zigsaw remote-modify --no-sign-key[=<fingerprint or identity>]`.
pub fn remove(ctx: *Context, prefix_arg: []const u8, which: ?[]const u8) !void {
    const arena = ctx.arena;
    const prefix = std.mem.trimEnd(u8, prefix_arg, "/");
    const file = try read(ctx);
    var kept: std.ArrayList(Entry) = .empty;
    var kept_keyless: std.ArrayList(KeylessEntry) = .empty;
    var removed: usize = 0;
    for (file.keys) |entry| {
        const named = std.ascii.eqlIgnoreCase(entry.prefix, prefix);
        // A key that can't be read can't be named by its fingerprint, so goes either way.
        const same = if (which) |f| if (signature.Key.parse(entry.key)) |k| std.mem.eql(u8, &k.fingerprint, f) else |_| true else true;
        if (named and same) removed += 1 else try kept.append(arena, entry);
    }
    for (file.keyless) |entry| {
        const named = std.ascii.eqlIgnoreCase(entry.prefix, prefix);
        const same = if (which) |w| std.mem.eql(u8, entry.san, w) else true;
        if (named and same) removed += 1 else try kept_keyless.append(arena, entry);
    }
    if (removed == 0) return fail("nobody was added for {s}{s}", .{ prefix, if (which != null) " by that" else "" });
    try write(ctx, .{ .keys = kept.items, .keyless = kept_keyless.items });
    note("removed {d} for {s}", .{ removed, prefix });
}

/// Whose signatures count for zigsaw's releases, as `zigsaw remotes` lists
/// them: the Release workflow's, for each version's tag, and the backup key.
pub fn releaseSigners() ![2]Signer {
    return .{
        .{ .keyless = .{ .issuer = sigstore.github_issuer, .san = release_workflow ++ "@refs/tags/v<version>" } },
        .{ .key = signature.Key.parse(published_keys[backup_key]) catch unreachable },
    };
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
    // The backup is the one iteration 74 recorded as kept offline.
    try std.testing.expectEqualStrings("5b6599a6da9c0ed0", &second.fingerprint);
}

test "a release's identity names its tag" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const id = try releaseIdentity(arena.allocator(), "0.81.0");
    try std.testing.expectEqualStrings("https://github.com/zigsaw-io/zigsaw/.github/workflows/release.yml@refs/tags/v0.81.0", id.san);
    try std.testing.expectEqualStrings(sigstore.github_issuer, id.issuer);
}
