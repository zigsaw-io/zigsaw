//! Registry credentials, and which registry each may go to.
//!
//! `zigsaw login <registry>` saves a login per registry host in Windows
//! Credential Manager, as a generic credential named `zigsaw:<host>` (per
//! user, encrypted by Windows). ZIGSAW_REGISTRY_USERNAME and
//! ZIGSAW_REGISTRY_PASSWORD, meant for CI and scripts, only go to the default
//! registry's host, so a token for one registry never reaches another.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
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

    pub const Source = enum { environment, credential_manager };

    /// Where the credentials came from, to complete "the credentials ...".
    pub fn origin(c: Credential) []const u8 {
        return switch (c.source) {
            .environment => "in " ++ username_var ++ " and " ++ password_var,
            .credential_manager => "saved by `zigsaw login`",
        };
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
/// they go to it, else a saved login. Null means anonymous.
pub fn lookup(ctx: *Context, host: []const u8) !?Credential {
    if (fromEnv(ctx)) |c| if (envAppliesTo(defaultRegistry(ctx), host)) return c;
    return read(ctx.arena, host);
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

// The console mode to restore if Ctrl+C ends zigsaw during a password prompt.
var prompt_console: ?win32.HANDLE = null;
var prompt_mode: win32.DWORD = 0;

fn restoreEcho(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    _ = event;
    if (prompt_console) |h| _ = win32.SetConsoleMode(h, prompt_mode);
    // Let the default handler end zigsaw.
    return win32.FALSE;
}

/// Asks for a line on the console, with or without echoing what's typed.
fn prompt(arena: Allocator, label: []const u8, echo: enum { echo, no_echo }) ![]const u8 {
    const console = win32.GetStdHandle(win32.STD_INPUT_HANDLE);
    var mode: win32.DWORD = 0;
    if (console == null or console == win32.INVALID_HANDLE_VALUE or win32.GetConsoleMode(console.?, &mode) == win32.FALSE)
        return fail("zigsaw login asks for the user name and password on a console; without one, use --username=<user> --password-stdin and pipe the password in", .{});
    const h = console.?;

    std.debug.print("{s}", .{label});
    if (echo == .no_echo) {
        prompt_console = h;
        prompt_mode = mode;
        _ = win32.SetConsoleCtrlHandler(&restoreEcho, win32.TRUE);
        if (win32.SetConsoleMode(h, (mode | win32.ENABLE_LINE_INPUT | win32.ENABLE_PROCESSED_INPUT) & ~win32.ENABLE_ECHO_INPUT) == win32.FALSE)
            return win32.lastErrorFail("turning off the console's echo (SetConsoleMode)");
    }
    defer if (echo == .no_echo) {
        _ = win32.SetConsoleMode(h, mode);
        _ = win32.SetConsoleCtrlHandler(&restoreEcho, win32.FALSE);
        prompt_console = null;
    };

    var line: std.ArrayList(u16) = .empty;
    const complete = while (std.mem.indexOfScalar(u16, line.items, '\n') == null) {
        var buf: [256]u16 = undefined;
        var n: win32.DWORD = 0;
        // Nothing read means Ctrl+C, or the end of input.
        if (win32.ReadConsoleW(h, &buf, buf.len, &n, null) == win32.FALSE or n == 0) break false;
        try line.appendSlice(arena, buf[0..n]);
    } else true;
    // The Enter that ended the line wasn't echoed either.
    if (echo == .no_echo) std.debug.print("\n", .{});
    if (!complete) return fail("login cancelled", .{});
    const end = std.mem.indexOfScalar(u16, line.items, '\n').?;
    const text = std.mem.trimEnd(u16, line.items[0..end], &.{'\r'});
    return std.unicode.wtf16LeToWtf8Alloc(arena, text);
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
