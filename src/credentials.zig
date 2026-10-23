//! Registry credentials, and which registry each may go to.
//!
//! `zigsaw login <registry>` saves a login per registry host in Windows
//! Credential Manager, as a generic credential named `zigsaw:<host>` (per
//! user, encrypted by Windows). ZIGSAW_REGISTRY_USERNAME and
//! ZIGSAW_REGISTRY_PASSWORD, meant for CI and scripts, only go to the default
//! registry's host, so a token for one registry never reaches another.
//! Without either, zigsaw uses the login `docker login` saved for the host:
//! from the credential helper Docker's config.json names, or in the file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const process = @import("process.zig");
const prompts = @import("prompt.zig");
const remote = @import("remote.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

pub const username_var = "ZIGSAW_REGISTRY_USERNAME";
pub const password_var = "ZIGSAW_REGISTRY_PASSWORD";

pub const Credential = struct {
    user: []const u8,
    secret: []const u8,
    source: Source,
    /// For `docker_helper`: "from docker-credential-<name>".
    helper: []const u8 = "",

    pub const Source = enum { environment, credential_manager, docker_config, docker_helper };

    /// Where the credentials came from, to complete "the credentials ...".
    pub fn origin(c: Credential) []const u8 {
        return switch (c.source) {
            .environment => "in " ++ username_var ++ " and " ++ password_var,
            .credential_manager => "saved by `zigsaw login`",
            .docker_config => "in Docker's config.json",
            .docker_helper => c.helper,
        };
    }

    /// Whether `docker login` saved them, rather than zigsaw.
    pub fn isDocker(c: Credential) bool {
        return c.source == .docker_config or c.source == .docker_helper;
    }
};

/// A registry host as logins are saved under it: without a scheme or path,
/// lowercase, and `docker.io` for Docker Hub by any of its names.
pub fn normalizeHost(arena: Allocator, text: []const u8) error{ InvalidHost, OutOfMemory }![]const u8 {
    const host = bareHost(text);
    if (!isValidHost(host)) return error.InvalidHost;
    return std.ascii.allocLowerString(arena, host);
}

/// `text` without a scheme or path, with Docker Hub's names folded into one.
fn bareHost(text: []const u8) []const u8 {
    var host = text;
    if (std.mem.indexOf(u8, host, "://")) |i| host = host[i + 3 ..];
    if (std.mem.indexOfScalar(u8, host, '/')) |i| host = host[0..i];
    for ([_][]const u8{ "index.docker.io", "registry-1.docker.io" }) |alias| {
        if (std.ascii.eqlIgnoreCase(host, alias)) return "docker.io";
    }
    return host;
}

pub fn isValidHost(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', ':', '[', ']' => {},
        else => return false,
    };
    return true;
}

/// The default registry, which the environment's credentials go to.
fn defaultRegistry(ctx: *const Context) []const u8 {
    return ctx.env.get(remote.registry_var) orelse remote.default_registry;
}

/// Whether credentials from the environment go to `host`: only when it is the
/// default registry's host.
pub fn envAppliesTo(default_registry: []const u8, host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(bareHost(default_registry), bareHost(host));
}

/// The environment's credentials, if both variables are set.
fn fromEnv(ctx: *const Context) ?Credential {
    return .{
        .user = ctx.env.get(username_var) orelse return null,
        .secret = ctx.env.get(password_var) orelse return null,
        .source = .environment,
    };
}

/// If the environment has credentials that don't go to `host`, the host they
/// do go to.
pub fn envHostOtherThan(ctx: *const Context, host: []const u8) ?[]const u8 {
    if (fromEnv(ctx) == null) return null;
    const registry = defaultRegistry(ctx);
    return if (envAppliesTo(registry, host)) null else bareHost(registry);
}

/// The credentials for a registry `host` (normalized): the environment's if
/// they go to it, else a login zigsaw saved, else one Docker saved. Null
/// means anonymous.
pub fn lookup(ctx: *Context, host: []const u8) !?Credential {
    if (fromEnv(ctx)) |c| if (envAppliesTo(defaultRegistry(ctx), host)) return c;
    if (try read(ctx.arena, host)) |c| return c;
    return fromDocker(ctx, host);
}

// ---------------------------------------------------------------------------
// Docker's logins

/// What `docker login` saves, in %DOCKER_CONFIG%\config.json, or else
/// %USERPROFILE%\.docker\config.json.
const DockerConfig = struct {
    /// By registry, as Docker names it: a host, or for Docker Hub
    /// "https://index.docker.io/v1/".
    auths: ?std.json.ArrayHashMap(DockerAuth) = null,
    /// The credential helper that keeps every registry's login.
    credsStore: ?[]const u8 = null,
    /// The credential helper that keeps a registry's login, by registry.
    credHelpers: ?std.json.ArrayHashMap([]const u8) = null,
};

const DockerAuth = struct {
    /// Base64 of "user:password".
    auth: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// An OAuth2 refresh token, which zigsaw doesn't use.
    identitytoken: ?[]const u8 = null,
};

/// Where Docker keeps a registry's login, as Docker itself decides: with the
/// helper its config names for the registry, else with the helper for all,
/// else in the file.
const DockerChoice = struct {
    helper: ?[]const u8 = null,
    /// What to ask the helper for: the registry as the config names it.
    server_url: []const u8,
    /// The login the file holds.
    stored: ?Credential = null,
    /// The file holds an identity token for the registry instead.
    identity_token: bool = false,
};

fn dockerChoice(arena: Allocator, config: DockerConfig, host: []const u8) !DockerChoice {
    var choice: DockerChoice = .{ .server_url = if (std.mem.eql(u8, host, "docker.io")) "https://index.docker.io/v1/" else host };
    var named = false;
    if (config.auths) |auths| for (auths.map.keys(), auths.map.values()) |key, a| {
        if (!sameHost(arena, key, host)) continue;
        choice.server_url = key;
        named = true;
        if (a.identitytoken) |t| if (t.len > 0) {
            choice.identity_token = true;
            break;
        };
        choice.stored = try storedLogin(arena, a);
        break;
    };
    if (config.credHelpers) |helpers| for (helpers.map.keys(), helpers.map.values()) |key, name| {
        if (!sameHost(arena, key, host) or name.len == 0) continue;
        choice.helper = name;
        if (!named) choice.server_url = key;
        return choice;
    };
    if (config.credsStore) |name| if (name.len > 0) {
        choice.helper = name;
    };
    return choice;
}

fn sameHost(arena: Allocator, key: []const u8, host: []const u8) bool {
    const h = normalizeHost(arena, key) catch return false;
    return std.mem.eql(u8, h, host);
}

/// A login the file holds itself: `auth`, base64 of "user:password", or
/// `username` and `password`.
fn storedLogin(arena: Allocator, a: DockerAuth) !?Credential {
    if (a.auth) |encoded| if (encoded.len > 0) {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch return null;
        const plain = try arena.alloc(u8, size);
        decoder.decode(plain, encoded) catch return null;
        const colon = std.mem.indexOfScalar(u8, plain, ':') orelse return null;
        if (colon == 0) return null;
        return .{ .user = plain[0..colon], .secret = plain[colon + 1 ..], .source = .docker_config };
    };
    const user = a.username orelse return null;
    const password = a.password orelse return null;
    if (user.len == 0) return null;
    return .{ .user = user, .secret = password, .source = .docker_config };
}

/// The login `docker login` saved for `host`, if Docker's config has one.
/// A config or helper that can't be used is noted, and left out.
fn fromDocker(ctx: *Context, host: []const u8) !?Credential {
    const arena = ctx.arena;
    const dir = ctx.env.get("DOCKER_CONFIG") orelse
        try std.fs.path.join(arena, &.{ ctx.env.get("USERPROFILE") orelse return null, ".docker" });
    const config_path = try std.fs.path.join(arena, &.{ dir, "config.json" });
    const bytes = Io.Dir.cwd().readFileAlloc(ctx.io, config_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        error.OutOfMemory => |e| return e,
        else => {
            note("warning: zigsaw can't read Docker's logins in {s} ({t}), and goes on without them", .{ config_path, err });
            return null;
        },
    };
    const config = std.json.parseFromSliceLeaky(DockerConfig, arena, bytes, .{ .ignore_unknown_fields = true }) catch {
        note("warning: zigsaw can't read Docker's logins in {s}, and goes on without them", .{config_path});
        return null;
    };
    const choice = try dockerChoice(arena, config, host);
    if (choice.identity_token and ctx.verbose)
        note("  Docker's login for {s} is an identity token, which zigsaw doesn't use", .{host});
    if (choice.helper) |name| if (try fromHelper(ctx, name, choice.server_url)) |c| return c;
    return choice.stored;
}

/// Asks Docker's credential helper `docker-credential-<name>` for the login
/// it keeps for `server_url`, as Docker does: `get`, with the registry on
/// stdin, and the login as JSON on stdout.
fn fromHelper(ctx: *Context, name: []const u8, server_url: []const u8) !?Credential {
    const arena = ctx.arena;
    const program = try std.fmt.allocPrint(arena, "docker-credential-{s}", .{name});
    const exe = try findOnPath(ctx, try std.fmt.allocPrint(arena, "{s}.exe", .{program})) orelse {
        if (ctx.verbose) note("  Docker's config names {s}, which isn't on PATH", .{program});
        return null;
    };
    var command_line: std.ArrayList(u8) = .empty;
    try process.appendQuoted(arena, &command_line, exe);
    try command_line.appendSlice(arena, " get");
    const answer = try process.output(arena, .{ .exe = exe, .command_line = command_line.items }, server_url, 30_000) orelse {
        note("warning: {s} didn't answer within 30 s; zigsaw goes on without Docker's login", .{program});
        return null;
    };
    // "credentials not found in native keychain", and the like.
    if (answer.code != 0) {
        if (ctx.verbose) note("  {s} has no login for {s}: {s}", .{ program, server_url, std.mem.trim(u8, answer.stdout, " \r\n") });
        return null;
    }
    const Login = struct { Username: []const u8 = "", Secret: []const u8 = "" };
    const saved = std.json.parseFromSliceLeaky(Login, arena, answer.stdout, .{ .ignore_unknown_fields = true }) catch {
        note("warning: zigsaw can't read what {s} answered, and goes on without Docker's login", .{program});
        return null;
    };
    if (std.mem.eql(u8, saved.Username, "<token>")) {
        if (ctx.verbose) note("  {s}'s login for {s} is an identity token, which zigsaw doesn't use", .{ program, server_url });
        return null;
    }
    if (saved.Username.len == 0) return null;
    return .{
        .user = saved.Username,
        .secret = saved.Secret,
        .source = .docker_helper,
        .helper = try std.fmt.allocPrint(arena, "from {s}", .{program}),
    };
}

/// Where `file` is in a directory on PATH, if it is.
fn findOnPath(ctx: *Context, file: []const u8) !?[]const u8 {
    const path = ctx.env.get("PATH") orelse ctx.env.get("Path") orelse return null;
    var dirs = std.mem.tokenizeScalar(u8, path, ';');
    while (dirs.next()) |dir| {
        const p = try std.fs.path.join(ctx.arena, &.{ std.mem.trim(u8, dir, "\""), file });
        Io.Dir.cwd().access(ctx.io, p, .{}) catch continue;
        return p;
    }
    return null;
}

fn targetName(arena: Allocator, host: []const u8) ![:0]u16 {
    return win32.wide(arena, try std.fmt.allocPrint(arena, "zigsaw:{s}", .{host}));
}

/// The login saved for `host`, if any.
fn read(arena: Allocator, host: []const u8) !?Credential {
    var found: ?*win32.CREDENTIALW = null;
    if (win32.CredReadW(try targetName(arena, host), win32.CRED_TYPE_GENERIC, 0, &found) == win32.FALSE) {
        if (win32.GetLastError() == win32.ERROR_NOT_FOUND) return null;
        return win32.lastErrorFail("reading the saved login (CredReadW)");
    }
    defer win32.CredFree(found);
    const c = found.?;
    return .{
        .user = if (c.UserName) |u| try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(u)) else "",
        .secret = if (c.CredentialBlob) |b| try arena.dupe(u8, b[0..c.CredentialBlobSize]) else "",
        .source = .credential_manager,
    };
}

/// Saves a login for `host`, replacing any saved before. The secret is stored
/// as UTF-8 bytes, as Docker's wincred helper does.
fn save(arena: Allocator, host: []const u8, user: []const u8, secret: []const u8) !void {
    if (secret.len > win32.CRED_MAX_CREDENTIAL_BLOB_SIZE)
        return fail("the password is {d} bytes; Windows Credential Manager holds at most {d}", .{ secret.len, win32.CRED_MAX_CREDENTIAL_BLOB_SIZE });
    const cred: win32.CREDENTIALW = .{
        .Type = win32.CRED_TYPE_GENERIC,
        .TargetName = try targetName(arena, host),
        .Comment = try win32.wide(arena, "Registry login saved by zigsaw login"),
        .CredentialBlobSize = @intCast(secret.len),
        .CredentialBlob = @constCast(secret.ptr),
        .Persist = win32.CRED_PERSIST_LOCAL_MACHINE,
        .UserName = try win32.wide(arena, user),
    };
    if (win32.CredWriteW(&cred, 0) == win32.FALSE) return win32.lastErrorFail("saving the login (CredWriteW)");
}

/// Deletes the login saved for `host`. False if there was none.
fn remove(arena: Allocator, host: []const u8) !bool {
    if (win32.CredDeleteW(try targetName(arena, host), win32.CRED_TYPE_GENERIC, 0) == win32.FALSE) {
        if (win32.GetLastError() == win32.ERROR_NOT_FOUND) return false;
        return win32.lastErrorFail("deleting the saved login (CredDeleteW)");
    }
    return true;
}

// ---------------------------------------------------------------------------
// zigsaw login / logout

pub const LoginOptions = struct {
    registry: []const u8,
    username: ?[]const u8 = null,
    password_stdin: bool = false,
};

/// `zigsaw login`: asks for credentials, checks them with the registry, and
/// saves them if it accepts them.
pub fn login(ctx: *Context, opts: LoginOptions) !void {
    const arena = ctx.arena;
    const host = try parseHost(arena, opts.registry);
    if (opts.password_stdin and opts.username == null)
        return fail("--password-stdin needs --username", .{});
    const user = opts.username orelse try prompt(arena, "Username: ", .echo);
    if (user.len == 0) return fail("the user name is empty", .{});
    // Basic authentication separates the user from the password with a colon.
    if (std.mem.indexOfScalar(u8, user, ':') != null) return fail("a user name can't contain ':'", .{});
    const secret = if (opts.password_stdin) try readStdin(ctx) else try prompt(arena, "Password: ", .no_echo);
    if (secret.len == 0) return fail("the password is empty", .{});

    switch (try Registry.checkLogin(ctx, host, .{ .user = user, .secret = secret, .source = .credential_manager })) {
        .accepted => {},
        .refused => return fail("{s} refused the credentials; nothing was saved", .{host}),
        .not_asked => note("{s} doesn't ask for credentials, so they couldn't be checked", .{host}),
    }
    try save(arena, host, user, secret);
    note("saved the login for {s} in Windows Credential Manager (zigsaw:{s})", .{ host, host });
    if (fromEnv(ctx) != null and envAppliesTo(defaultRegistry(ctx), host))
        note("while {s} and {s} are set, those go to {s} instead", .{ username_var, password_var, host });
}

/// `zigsaw logout`: deletes the login saved for a registry.
pub fn logout(ctx: *Context, registry: []const u8) !void {
    const arena = ctx.arena;
    const host = try parseHost(arena, registry);
    if (try remove(arena, host)) {
        note("removed the login for {s}", .{host});
    } else {
        note("no login is saved for {s}", .{host});
    }
    if (fromEnv(ctx) != null and envAppliesTo(defaultRegistry(ctx), host))
        note("{s} and {s} still go to {s}", .{ username_var, password_var, host });
}

fn parseHost(arena: Allocator, text: []const u8) ![]const u8 {
    return normalizeHost(arena, text) catch |err| switch (err) {
        error.InvalidHost => fail("\"{s}\" isn't a registry, like ghcr.io or localhost:5000", .{text}),
        error.OutOfMemory => |e| e,
    };
}

/// The password from stdin, without the line break that ends it.
fn readStdin(ctx: *Context) ![]const u8 {
    var buf: [1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(ctx.io, &buf);
    const text = reader.interface.allocRemaining(ctx.arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return fail("stdin is too long to be a password", .{}),
        error.ReadFailed => return fail("reading the password from stdin: {t}", .{reader.err.?}),
        error.OutOfMemory => |e| return e,
    };
    return std.mem.trimEnd(u8, text, "\r\n");
}

/// Asks for a line on the console, with or without echoing what's typed.
fn prompt(arena: Allocator, label: []const u8, echo: prompts.Echo) ![]const u8 {
    const line = prompts.consoleLine(arena, label, echo) catch |err| switch (err) {
        error.EndOfInput => return fail("login cancelled", .{}),
        else => |e| return e,
    };
    return line orelse fail("zigsaw login asks for the user name and password on a console; without one, use --username=<user> --password-stdin and pipe the password in", .{});
}

test normalizeHost {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "ghcr.io", .want = "ghcr.io" },
        .{ .in = "GHCR.io", .want = "ghcr.io" },
        .{ .in = "https://ghcr.io/v2/", .want = "ghcr.io" },
        .{ .in = "ghcr.io/zigsaw-io", .want = "ghcr.io" },
        .{ .in = "localhost:5000/test/", .want = "localhost:5000" },
        .{ .in = "http://127.0.0.1:5001", .want = "127.0.0.1:5001" },
        .{ .in = "docker.io", .want = "docker.io" },
        .{ .in = "index.docker.io", .want = "docker.io" },
        .{ .in = "https://index.docker.io/v1/", .want = "docker.io" },
        .{ .in = "Registry-1.Docker.io", .want = "docker.io" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.want, try normalizeHost(arena, c.in));
    for ([_][]const u8{ "", "https://", "/path", "a b.io", "user@ghcr.io" }) |bad| {
        try std.testing.expectError(error.InvalidHost, normalizeHost(arena, bad));
    }
}

test dockerChoice {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\{"auths": {
        \\   "https://index.docker.io/v1/": {"auth": "dXNlcjpwYTpzcw=="},
        \\   "localhost:5001": {"username": "bob", "password": "pw"},
        \\   "quay.io": {"auth": "dTo=", "identitytoken": "refresh"},
        \\   "ghcr.io": {}
        \\ },
        \\ "credsStore": "desktop",
        \\ "credHelpers": {"ghcr.io": "gh", "https://gcr.io": "gcloud"}}
    ;
    const config = try std.json.parseFromSliceLeaky(DockerConfig, arena, json, .{ .ignore_unknown_fields = true });

    // Docker Hub: in the file, under its URL, and the helper for all is asked first.
    const hub = try dockerChoice(arena, config, "docker.io");
    try std.testing.expectEqualStrings("desktop", hub.helper.?);
    try std.testing.expectEqualStrings("https://index.docker.io/v1/", hub.server_url);
    try std.testing.expectEqualStrings("user", hub.stored.?.user);
    try std.testing.expectEqualStrings("pa:ss", hub.stored.?.secret);
    try std.testing.expectEqual(Credential.Source.docker_config, hub.stored.?.source);

    // A registry's own helper wins over the one for all.
    const ghcr = try dockerChoice(arena, config, "ghcr.io");
    try std.testing.expectEqualStrings("gh", ghcr.helper.?);
    try std.testing.expectEqualStrings("ghcr.io", ghcr.server_url);
    try std.testing.expectEqual(null, ghcr.stored);
    const gcr = try dockerChoice(arena, config, "gcr.io");
    try std.testing.expectEqualStrings("gcloud", gcr.helper.?);
    try std.testing.expectEqualStrings("https://gcr.io", gcr.server_url);

    try std.testing.expectEqualStrings("bob", (try dockerChoice(arena, config, "localhost:5001")).stored.?.user);
    const quay = try dockerChoice(arena, config, "quay.io");
    try std.testing.expect(quay.identity_token);
    try std.testing.expectEqual(null, quay.stored);

    // Without helpers: the file alone, and nothing for a registry it doesn't name.
    const file_only = try std.json.parseFromSliceLeaky(DockerConfig, arena, "{\"auths\": {\"localhost:5001\": {\"auth\": \"Ym9iOnB3\"}}}", .{});
    const local = try dockerChoice(arena, file_only, "localhost:5001");
    try std.testing.expectEqual(null, local.helper);
    try std.testing.expectEqualStrings("bob", local.stored.?.user);
    try std.testing.expectEqualStrings("pw", local.stored.?.secret);
    const other = try dockerChoice(arena, file_only, "example.com");
    try std.testing.expectEqual(null, other.helper);
    try std.testing.expectEqual(null, other.stored);
    try std.testing.expectEqualStrings("example.com", other.server_url);
}

test envAppliesTo {
    // Only the default registry's host gets the environment's credentials.
    try std.testing.expect(envAppliesTo(remote.default_registry, "ghcr.io"));
    try std.testing.expect(envAppliesTo("ghcr.io/you", "GHCR.IO"));
    try std.testing.expect(envAppliesTo("localhost:5000/test/", "localhost:5000"));
    try std.testing.expect(envAppliesTo("docker.io/you", "registry-1.docker.io"));
    try std.testing.expect(!envAppliesTo(remote.default_registry, "docker.io"));
    try std.testing.expect(!envAppliesTo(remote.default_registry, "ghcr.io.evil.example"));
    try std.testing.expect(!envAppliesTo("localhost:5000/test", "localhost:5001"));
    try std.testing.expect(!envAppliesTo("localhost:5000", "localhost"));
}
