//! Remotes, as Flatpak has them: named places where apps' images are, each a
//! registry and a path in it, so that an app is named by its id alone. The
//! remote `zigsaw` is ghcr.io/zigsaw-io: `zigsaw install org.nodejs.node`
//! installs ghcr.io/zigsaw-io/org.nodejs.node.
//!
//! A store keeps its remotes in remotes.json, in order; one without the file
//! has `zigsaw` alone. An app named by id comes from the first, unless the
//! command names another (`zigsaw install <remote> <app-id>`), and publishing
//! goes to the first unless told otherwise. ZIGSAW_REGISTRY, for CI and tests,
//! is where the first is instead; nothing saves it.
//!
//! What a remote has besides its location stays where it was before remotes
//! (0.105): whose signatures count for its images are trust.zig's entries for
//! its location, zigsaw-io's built in; its login is credentials.zig's, for its
//! registry's host. Entries `zigsaw trust add` made for a place no remote is
//! become remotes of their own, named after its last part.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const credentials = @import("credentials.zig");
const output = @import("output.zig");
const remote = @import("remote.zig");
const sigstore = @import("sigstore.zig");
const trust = @import("trust.zig");
const fail = Context.fail;
const note = Context.note;

pub const Remote = struct {
    name: []const u8,
    /// A registry and a path in it: ghcr.io/zigsaw-io, localhost:5000.
    url: []const u8,
};

/// The one a store has until told otherwise.
pub const default_name = "zigsaw";

const File = struct { remotes: []const Remote = &.{} };

fn filePath(ctx: *Context) ![]const u8 {
    return ctx.store.path(ctx.arena, &.{"remotes.json"});
}

/// The remotes as the store keeps them, without ZIGSAW_REGISTRY.
fn saved(ctx: *Context) ![]const Remote {
    const arena = ctx.arena;
    const p = try filePath(ctx);
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, p, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return adopt(ctx, &.{.{ .name = default_name, .url = remote.default_registry }}),
        else => |e| return e,
    };
    const file = std.json.parseFromSliceLeaky(File, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return fail("{s} isn't what zigsaw wrote: fix or delete it", .{p});
    return adopt(ctx, file.remotes);
}

fn write(ctx: *Context, list: []const Remote) !void {
    const p = try filePath(ctx);
    const tmp = try ctx.store.tmpPath(ctx.arena, "remotes");
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = try @import("oci.zig").toJson(ctx.arena, File{ .remotes = list }) });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), p, ctx.io);
}

/// `list` and a remote for every place `zigsaw trust add` named before
/// remotes that none of them is, which are then saved.
fn adopt(ctx: *Context, list: []const Remote) ![]const Remote {
    const arena = ctx.arena;
    var out: std.ArrayList(Remote) = .empty;
    try out.appendSlice(arena, list);
    var added: std.ArrayList([]const u8) = .empty;
    for (try trust.addedPrefixes(ctx)) |prefix| {
        if (indexOfUrl(out.items, prefix) != null) continue;
        const name = try freeName(arena, out.items, prefix);
        try out.append(arena, .{ .name = name, .url = prefix });
        try added.append(arena, name);
    }
    if (added.items.len > 0) {
        try write(ctx, out.items);
        note("note: the places `zigsaw trust add` named are remotes now, which `zigsaw remotes` lists: {s}", .{try std.mem.join(arena, ", ", added.items)});
    }
    return out.items;
}

fn sameUrl(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn indexOfUrl(list: []const Remote, url: []const u8) ?usize {
    for (list, 0..) |r, i| if (sameUrl(r.url, url)) return i;
    return null;
}

fn indexOfName(list: []const Remote, name: []const u8) ?usize {
    for (list, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) return i;
    return null;
}

/// A name for a remote at `url` that none in `list` has: its last part, as
/// a name may be.
fn freeName(arena: Allocator, list: []const Remote, url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    var last = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |s| s + 1 else 0..];
    if (std.mem.indexOfScalar(u8, last, ':')) |colon| last = last[0..colon];
    var base: std.ArrayList(u8) = .empty;
    for (last) |c| try base.append(arena, if (std.ascii.isAlphanumeric(c) or c == '_') std.ascii.toLower(c) else '-');
    const start = std.mem.trimStart(u8, base.items, "-_");
    var name: []const u8 = if (start.len == 0) "remote" else start[0..@min(start.len, 56)];
    var n: usize = 2;
    while (indexOfName(list, name) != null) : (n += 1) name = try std.fmt.allocPrint(arena, "{s}-{d}", .{ name[0..@min(name.len, 56)], n });
    return name;
}

/// Whether `text` may name a remote: letters, digits, '-' and '_', from a
/// letter or digit, with no '.', ':' or '/', so that it's never an app's id
/// or an image's name.
pub fn isName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64 or !std.ascii.isAlphanumeric(text[0])) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// A remote's location as given: ghcr.io/me, localhost:5000, or with
/// Flatpak's oci+https:// before it.
pub fn parseLocation(arena: Allocator, text: []const u8) ![]const u8 {
    var t = text;
    for ([_][]const u8{ "oci+https://", "oci+http://", "https://", "http://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(t, scheme)) {
            t = t[scheme.len..];
            break;
        }
    }
    t = std.mem.trimEnd(u8, t, "/");
    if (t.len == 0 or std.mem.indexOfAny(u8, t, " \t\r\n\"\\@") != null) return badLocation(text);
    // A location is what goes before an app's id in its image's name.
    const ref = Registry.Reference.parse(try std.fmt.allocPrint(arena, "{s}/app", .{t})) catch return badLocation(text);
    if (ref.tag != null) return badLocation(text);
    return t;
}

fn badLocation(text: []const u8) error{Failed} {
    return fail("\"{s}\" isn't where images are: give a registry and a path in it, like ghcr.io/me or localhost:5000", .{text});
}

/// The registry host a location is on.
pub fn hostOf(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfScalar(u8, url, '/') orelse url.len];
}

/// The remotes, in order: the first where ZIGSAW_REGISTRY says, if it's set.
/// Without an open store (doctor, which changes nothing), `zigsaw` alone.
pub fn all(ctx: *Context) ![]const Remote {
    const list = if (ctx.store_open) try saved(ctx) else &[_]Remote{.{ .name = default_name, .url = remote.default_registry }};
    const env = ctx.env.get(remote.registry_var) orelse return list;
    const url = std.mem.trimEnd(u8, env, "/");
    if (list.len == 0) return ctx.arena.dupe(Remote, &.{.{ .name = default_name, .url = url }});
    const out = try ctx.arena.dupe(Remote, list);
    out[0].url = url;
    return out;
}

/// Where apps named by id alone are: at the remote this command names, or
/// else the first. Null when there's no remote.
pub fn defaultUrl(ctx: *Context) !?[]const u8 {
    if (ctx.remote) |url| return url;
    const list = try all(ctx);
    return if (list.len > 0) list[0].url else null;
}

pub fn find(ctx: *Context, name: []const u8) !?Remote {
    const list = try all(ctx);
    return if (indexOfName(list, name)) |i| list[i] else null;
}

/// The remote named so, or a failure saying there's none.
pub fn named(ctx: *Context, name: []const u8) !Remote {
    return try find(ctx, name) orelse fail("no remote is named \"{s}\": `zigsaw remotes` lists them", .{name});
}

/// Makes the remote named so where this command's apps named by id are.
pub fn use(ctx: *Context, name: []const u8) !void {
    ctx.remote = (try named(ctx, name)).url;
}

/// The remote an image reference is under, if any.
pub fn of(ctx: *Context, reference: []const u8) !?Remote {
    const ref = Registry.Reference.parse(reference) catch return null;
    const repository = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ref.host, ref.repository });
    for (try all(ctx)) |r| if (trust.underPrefix(r.url, repository)) return r;
    return null;
}

/// What to run for a login to `host`, for messages that ask for one. Reads
/// the store's remotes only when it's open.
pub fn loginHint(ctx: *Context, host: []const u8) []const u8 {
    const arena = ctx.arena;
    const fallback = std.fmt.allocPrint(arena, "`zigsaw remote-add --login <name> {s}/<path>`", .{host}) catch return "zigsaw remote-modify --login";
    if (!ctx.store_open) return fallback;
    const list = all(ctx) catch return fallback;
    for (list) |r| if (credentials.normalizeHost(arena, hostOf(r.url))) |h| {
        if (std.ascii.eqlIgnoreCase(h, host))
            return std.fmt.allocPrint(arena, "`zigsaw remote-modify --login {s}`", .{r.name}) catch fallback;
    } else |_| {};
    return fallback;
}

// ---------------------------------------------------------------------------
// The commands

/// `zigsaw remotes`: each remote, whose signatures count for its images, and
/// its login; then whose count for zigsaw's releases.
pub fn show(ctx: *Context) !void {
    const arena = ctx.arena;
    const remotes = try all(ctx);
    const signers = try trust.all(ctx);
    const env = ctx.env.get(remote.registry_var);
    if (ctx.format == .json) return showJson(ctx, remotes, signers, env != null);
    var width: usize = 0;
    for (remotes) |r| width = @max(width, r.name.len);
    var buf: [4096]u8 = undefined;
    var stdout = Context.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    for (remotes, 0..) |r, i| {
        try w.print("{s}", .{r.name});
        try w.splatByteAll(' ', width - r.name.len + 2);
        try w.print("{s}{s}{s}\n", .{
            r.url,
            if (i == 0) "  (the default)" else "",
            if (i == 0 and env != null) "  (from " ++ remote.registry_var ++ ")" else "",
        });
        for (signers) |s| if (sameUrl(s.prefix, r.url)) try w.print("  signed by {s}{f}{s}\n", .{
            if (s.signer == .keyless) "keyless " else "",
            s.signer,
            if (s.built_in) ", built in" else "",
        });
        const host = credentials.normalizeHost(arena, hostOf(r.url)) catch continue;
        switch (try credentials.savedFor(ctx, host)) {
            .none, .docker_unreadable => {},
            .environment => try w.print("  login     in {s} and {s}\n", .{ credentials.username_var, credentials.password_var }),
            .credential_manager => |user| try w.print("  login     {s}\n", .{user}),
            .docker_config => try w.print("  login     Docker's, in its config.json\n", .{}),
            .docker_helper => |name| try w.print("  login     Docker's, with docker-credential-{s}\n", .{name}),
        }
    }
    try w.print("zigsaw's releases\n", .{});
    for (try trust.releaseSigners()) |s| try w.print("  signed by {s}{f}, built in\n", .{ if (s == .keyless) "keyless " else "", s });
    try w.flush();
}

/// A signer, as `remotes --format=json` has it.
const JsonSigner = struct {
    kind: enum { key, keyless },
    /// A key's fingerprint.
    key: ?[]const u8 = null,
    /// The identity a keyless signature's certificate must name, and who
    /// gave it.
    identity: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    built_in: bool,

    fn of(arena: Allocator, s: trust.Signer, built_in: bool) !JsonSigner {
        return switch (s) {
            .key => |k| .{ .kind = .key, .key = try arena.dupe(u8, &k.fingerprint), .built_in = built_in },
            .keyless => |id| .{ .kind = .keyless, .identity = id.san, .issuer = id.issuer, .built_in = built_in },
        };
    }
};

/// A remote, as `remotes --format=json` has it.
const JsonRemote = struct {
    name: []const u8,
    url: []const u8,
    /// The first: where apps named by id alone come from.
    default: bool,
    /// Whether ZIGSAW_REGISTRY moved it, for this command.
    from_env: bool,
    signers: []const JsonSigner,
    /// The login its registry gets; null if none.
    login: ?struct {
        kind: enum { environment, credential_manager, docker_config, docker_helper },
        username: ?[]const u8 = null,
        helper: ?[]const u8 = null,
    },
};

fn showJson(ctx: *Context, remotes: []const Remote, signers: []const trust.Named, from_env: bool) !void {
    const arena = ctx.arena;
    const out = try arena.alloc(JsonRemote, remotes.len);
    for (out, remotes, 0..) |*o, r, i| {
        var theirs: std.ArrayList(JsonSigner) = .empty;
        for (signers) |s| if (sameUrl(s.prefix, r.url)) try theirs.append(arena, try .of(arena, s.signer, s.built_in));
        o.* = .{ .name = r.name, .url = r.url, .default = i == 0, .from_env = i == 0 and from_env, .signers = theirs.items, .login = null };
        const host = credentials.normalizeHost(arena, hostOf(r.url)) catch continue;
        o.login = switch (try credentials.savedFor(ctx, host)) {
            .none, .docker_unreadable => null,
            .environment => .{ .kind = .environment },
            .credential_manager => |user| .{ .kind = .credential_manager, .username = user },
            .docker_config => .{ .kind = .docker_config },
            .docker_helper => |name| .{ .kind = .docker_helper, .helper = name },
        };
    }
    var releases: std.ArrayList(JsonSigner) = .empty;
    for (try trust.releaseSigners()) |s| try releases.append(arena, try .of(arena, s, true));
    try output.write(ctx, .{ .remotes = out, .releases = .{ .signers = releases.items } });
}

/// What `remote-add` and `remote-modify` change, in this order: the
/// location, signatures taken away, then added, the login.
pub const Changes = struct {
    url: ?[]const u8 = null,
    /// Key files, as `cosign generate-key-pair` makes cosign.pub.
    sign_keys: []const []const u8 = &.{},
    /// An identity a keyless signature's certificate must name.
    keyless: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    /// `--no-sign-key`: everyone added, or the one with this fingerprint or
    /// identity.
    no_sign_key: ?Which = null,
    login: bool = false,
    username: ?[]const u8 = null,
    password_stdin: bool = false,
    logout: bool = false,

    pub const Which = union(enum) { all, one: []const u8 };

    fn none(c: Changes) bool {
        return c.url == null and c.sign_keys.len == 0 and c.keyless == null and c.no_sign_key == null and !c.login and !c.logout;
    }
};

/// `zigsaw remote-add <name> <location>`.
pub fn add(ctx: *Context, name: []const u8, location: []const u8, changes: Changes, if_not_exists: bool) !void {
    const arena = ctx.arena;
    if (!isName(name)) return fail("\"{s}\" can't name a remote: give letters, digits, '-' and '_', with no '.'", .{name});
    const url = try parseLocation(arena, location);
    const list = try saved(ctx);
    if (indexOfName(list, name)) |i| {
        if (if_not_exists) {
            note("{s} is a remote already, at {s}", .{ name, list[i].url });
            return;
        }
        return fail("{s} is a remote already, at {s}: `zigsaw remote-modify --url=<location> {s}` moves it", .{ name, list[i].url, name });
    }
    if (indexOfUrl(list, url)) |i| return fail("{s} is the remote {s} already", .{ url, list[i].name });
    // All or nothing: no remote is added that its signers couldn't be.
    try trust.check(ctx, changes.sign_keys, changes.keyless, changes.issuer orelse sigstore.github_issuer);
    var out: std.ArrayList(Remote) = .empty;
    try out.appendSlice(arena, list);
    try out.append(arena, .{ .name = name, .url = url });
    try write(ctx, out.items);
    note("added the remote {s}, at {s}{s}", .{ name, url, if (out.items.len == 1) ": apps named by id alone come from it" else "" });
    var rest = changes;
    rest.url = null;
    try apply(ctx, .{ .name = name, .url = url }, rest);
}

/// `zigsaw remote-modify <name>`.
pub fn modify(ctx: *Context, name: []const u8, changes: Changes) !void {
    if (changes.none()) return fail("nothing to change: give --url, --sign-key, --keyless, --no-sign-key, --login or --logout", .{});
    const list = try saved(ctx);
    const i = indexOfName(list, name) orelse return fail("no remote is named \"{s}\": `zigsaw remotes` lists them", .{name});
    try apply(ctx, list[i], changes);
}

fn apply(ctx: *Context, r: Remote, changes: Changes) !void {
    const arena = ctx.arena;
    var url = r.url;
    if (changes.url) |location| {
        const new = try parseLocation(arena, location);
        const list = try saved(ctx);
        if (indexOfUrl(list, new)) |j| if (!std.mem.eql(u8, list[j].name, r.name)) return fail("{s} is the remote {s} already", .{ new, list[j].name });
        const out = try arena.dupe(Remote, list);
        out[indexOfName(list, r.name).?].url = new;
        // Whose signatures counted there count where it is now.
        const moved = try trust.movePrefix(ctx, r.url, new);
        try write(ctx, out);
        note("{s} is at {s} now{s}", .{ r.name, new, if (moved > 0) ", with the signers it had" else "" });
        url = new;
    }
    if (changes.no_sign_key) |which| try trust.remove(ctx, url, switch (which) {
        .all => null,
        .one => |w| w,
    });
    for (changes.sign_keys) |file| try trust.add(ctx, url, file);
    if (changes.keyless) |san| try trust.addKeyless(ctx, url, san, changes.issuer orelse sigstore.github_issuer);
    if (changes.logout) try credentials.logout(ctx, hostOf(url));
    if (changes.login) try credentials.login(ctx, .{ .registry = hostOf(url), .username = changes.username, .password_stdin = changes.password_stdin });
}

/// `zigsaw remote-delete [--force] <name>`: the remote, and whose signatures
/// counted for it. Not one apps were installed from, unless forced: their
/// updates would no longer be checked for its signatures. Its registry's
/// login stays: Windows keeps it for the user, and every store uses it.
pub fn delete(ctx: *Context, name: []const u8, force: bool) !void {
    const arena = ctx.arena;
    const list = try saved(ctx);
    const i = indexOfName(list, name) orelse return fail("no remote is named \"{s}\": `zigsaw remotes` lists them", .{name});
    const r = list[i];
    if (!force) {
        var from: std.ArrayList([]const u8) = .empty;
        for (try ctx.store.listRefs(arena)) |ref| {
            const source = ref.source orelse continue;
            const parsed = Registry.Reference.parse(source) catch continue;
            if (trust.underPrefix(r.url, try std.fmt.allocPrint(arena, "{s}/{s}", .{ parsed.host, parsed.repository }))) try from.append(arena, ref.id);
        }
        if (from.items.len > 0) return fail("{s} was installed from {s}: their updates come from there, checked for its signatures; --force deletes it all the same", .{ try std.mem.join(arena, ", ", from.items), name });
    }
    var out: std.ArrayList(Remote) = .empty;
    for (list, 0..) |other, j| if (j != i) try out.append(arena, other);
    try write(ctx, out.items);
    const signers = try trust.removeAll(ctx, r.url);
    note("deleted the remote {s}{s}", .{ name, if (signers > 0) ", and whose signatures counted for it" else "" });
    if (out.items.len == 0) note("there's no remote left: apps named by id alone can't be installed until `zigsaw remote-add`", .{});
    const host = hostOf(r.url);
    for (out.items) |other| if (std.ascii.eqlIgnoreCase(hostOf(other.url), host)) return;
    const normal = credentials.normalizeHost(arena, host) catch return;
    switch (try credentials.savedFor(ctx, normal)) {
        .credential_manager => note("the login saved for {s} stays, for zigsaw's other stores: with the remote added again, `zigsaw remote-modify --logout {s}` deletes it", .{ normal, name }),
        else => {},
    }
}

test isName {
    try std.testing.expect(isName("zigsaw"));
    try std.testing.expect(isName("my-apps_2"));
    try std.testing.expect(!isName(""));
    try std.testing.expect(!isName("-x"));
    try std.testing.expect(!isName("org.nodejs.node"));
    try std.testing.expect(!isName("localhost:5000"));
    try std.testing.expect(!isName("ghcr.io/me"));
}

test parseLocation {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("ghcr.io/zigsaw-io", try parseLocation(arena, "ghcr.io/zigsaw-io/"));
    try std.testing.expectEqualStrings("ghcr.io/zigsaw-io", try parseLocation(arena, "oci+https://ghcr.io/zigsaw-io"));
    try std.testing.expectEqualStrings("localhost:5000", try parseLocation(arena, "localhost:5000"));
    try std.testing.expectEqualStrings("localhost:5000/a/b", try parseLocation(arena, "oci+http://localhost:5000/a/b"));
    try std.testing.expectEqualStrings("ghcr.io", hostOf("ghcr.io/zigsaw-io"));
    try std.testing.expectEqualStrings("localhost:5000", hostOf("localhost:5000"));
}

test freeName {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("acme", try freeName(arena, &.{}, "ghcr.io/acme"));
    try std.testing.expectEqualStrings("localhost", try freeName(arena, &.{}, "localhost:5000"));
    try std.testing.expectEqualStrings("org-foo-app", try freeName(arena, &.{}, "ghcr.io/me/org.foo.app/"));
    try std.testing.expectEqualStrings("acme-2", try freeName(arena, &.{.{ .name = "acme", .url = "x.io/acme" }}, "ghcr.io/acme"));
}
