//! A client for OCI registries: the OCI Distribution API for manifests and
//! blobs, and the token authentication that registries such as ghcr.io and
//! Docker Hub use.

const Registry = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const Context = @import("Context.zig");
const Store = @import("Store.zig");
const oci = @import("oci.zig");
const fail = Context.fail;

ctx: *Context,
client: http.Client,
ref: Reference,
/// What the registry token must allow: "pull", or "pull,push".
actions: []const u8,
/// The Authorization header value, once the registry has asked for one.
authorization: ?[]const u8 = null,

/// Environment variables holding registry credentials, for pushing and for
/// pulling private images.
pub const username_var = "ZIGSAW_REGISTRY_USERNAME";
pub const password_var = "ZIGSAW_REGISTRY_PASSWORD";

pub fn init(r: *Registry, ctx: *Context, ref: Reference, actions: []const u8) !void {
    r.* = .{
        .ctx = ctx,
        .client = .{ .allocator = ctx.gpa, .io = ctx.io },
        .ref = ref,
        .actions = actions,
    };
    try r.client.initDefaultProxies(ctx.arena, ctx.env);
}

pub fn deinit(r: *Registry) void {
    r.client.deinit();
}

/// An image in a registry: `<host>/<repository>[:<tag>][@<digest>]`.
pub const Reference = struct {
    /// As written, e.g. "ghcr.io" or "localhost:5000".
    host: []const u8,
    repository: []const u8,
    tag: ?[]const u8 = null,
    digest: ?[]const u8 = null,

    pub fn parse(text: []const u8) error{InvalidReference}!Reference {
        var rest = text;
        var ref: Reference = undefined;
        ref.digest = null;
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            ref.digest = rest[at + 1 ..];
            if (oci.digestHex(ref.digest.?) == null) return error.InvalidReference;
            rest = rest[0..at];
        }
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidReference;
        ref.host = rest[0..slash];
        if (!looksLikeHost(ref.host)) return error.InvalidReference;
        rest = rest[slash + 1 ..];
        ref.tag = null;
        if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
            ref.tag = rest[colon + 1 ..];
            if (!isValidTag(ref.tag.?)) return error.InvalidReference;
            rest = rest[0..colon];
        }
        ref.repository = rest;
        if (!isValidRepository(ref.repository)) return error.InvalidReference;
        return ref;
    }

    /// What to ask the manifests endpoint for.
    pub fn manifestRef(ref: Reference) []const u8 {
        return ref.digest orelse ref.tag orelse "latest";
    }

    /// Registries on this machine are spoken to over plain HTTP, as Docker does.
    fn baseUrl(ref: Reference, arena: Allocator) ![]const u8 {
        const name = if (std.mem.lastIndexOfScalar(u8, ref.host, ':')) |c| ref.host[0..c] else ref.host;
        const local = std.mem.eql(u8, name, "localhost") or std.mem.eql(u8, name, "127.0.0.1") or std.mem.eql(u8, name, "[::1]");
        // docker.io is the name people use; its API lives elsewhere.
        const api_host = if (std.mem.eql(u8, ref.host, "docker.io")) "registry-1.docker.io" else ref.host;
        return std.fmt.allocPrint(arena, "{s}://{s}", .{ if (local) "http" else "https", api_host });
    }

    pub fn format(ref: Reference, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{s}/{s}", .{ ref.host, ref.repository });
        if (ref.tag) |t| try w.print(":{s}", .{t});
        if (ref.digest) |d| try w.print("@{s}", .{d});
    }

    fn looksLikeHost(s: []const u8) bool {
        return std.mem.indexOfAny(u8, s, ".:") != null or std.mem.eql(u8, s, "localhost");
    }

    /// Lowercase path components of letters, digits and single separators.
    fn isValidRepository(s: []const u8) bool {
        var parts = std.mem.splitScalar(u8, s, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or !std.ascii.isAlphanumeric(part[0]) or !std.ascii.isAlphanumeric(part[part.len - 1])) return false;
            for (part) |c| switch (c) {
                'a'...'z', '0'...'9', '.', '_', '-' => {},
                else => return false,
            };
        }
        return true;
    }

    pub fn isValidTag(s: []const u8) bool {
        if (s.len == 0 or s.len > 128 or s[0] == '.' or s[0] == '-') return false;
        for (s) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        };
        return true;
    }
};

pub const Manifest = struct {
    bytes: []const u8,
    /// "sha256:<hex>" of `bytes`.
    digest: []const u8,
};

const accept_manifests = oci.media_type.manifest ++ ", " ++
    "application/vnd.oci.image.index.v1+json, " ++
    "application/vnd.docker.distribution.manifest.v2+json, " ++
    "application/vnd.docker.distribution.manifest.list.v2+json";

pub fn fetchManifest(r: *Registry) !Manifest {
    const res = try r.send(.{
        .method = .GET,
        .url = try r.url("/v2/{s}/manifests/{s}", .{ r.ref.repository, r.ref.manifestRef() }),
        .accept = accept_manifests,
    });
    if (res.status != .ok) return r.failStatus(res, "fetching the manifest");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(res.body, &digest, .{});
    return .{
        .bytes = res.body,
        .digest = try std.fmt.allocPrint(r.ctx.arena, "sha256:{s}", .{&std.fmt.bytesToHex(digest, .lower)}),
    };
}

pub fn hasBlob(r: *Registry, digest: []const u8) !bool {
    const res = try r.send(.{ .method = .HEAD, .url = try r.url("/v2/{s}/blobs/{s}", .{ r.ref.repository, digest }) });
    return switch (res.status) {
        .ok => true,
        .not_found => false,
        else => r.failStatus(res, "checking for a blob"),
    };
}

/// Downloads a blob to `dest` and checks it against its descriptor.
pub fn downloadBlob(r: *Registry, desc: oci.Descriptor, dest: []const u8) !Store.FileHash {
    const io = r.ctx.io;
    var file = try Io.Dir.cwd().createFile(io, dest, .{ .read = true });
    errdefer Io.Dir.cwd().deleteFile(io, dest) catch {};
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = file_writer.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);

    const res = try r.send(.{
        .method = .GET,
        .url = try r.url("/v2/{s}/blobs/{s}", .{ r.ref.repository, desc.digest }),
        .sink = &hashed.writer,
    });
    if (res.status != .ok) return r.failStatus(res, "downloading a blob");
    try hashed.writer.flush();
    try file_writer.interface.flush();

    const hash: Store.FileHash = .{ .hex = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower), .size = try file.length(io) };
    if (!std.mem.eql(u8, &hash.hex, oci.digestHex(desc.digest).?) or hash.size != desc.size)
        return fail("blob {s} from {f} doesn't match its digest", .{ desc.digest, r.ref });
    return hash;
}

/// Uploads the file at `path` as a blob, in one request.
pub fn uploadBlob(r: *Registry, desc: oci.Descriptor, path: []const u8) !void {
    const arena = r.ctx.arena;
    const start = try r.send(.{ .method = .POST, .url = try r.url("/v2/{s}/blobs/uploads/", .{r.ref.repository}) });
    if (start.status != .accepted) return r.failStatus(start, "starting an upload");
    const location = start.location orelse return fail("{f} started an upload without saying where to send it", .{r.ref});

    var put_url: std.ArrayList(u8) = .empty;
    // The location may be a full URL or a path on the registry.
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        try put_url.appendSlice(arena, location);
    } else {
        try put_url.appendSlice(arena, try r.url("{s}", .{location}));
    }
    try put_url.appendSlice(arena, if (std.mem.indexOfScalar(u8, location, '?') == null) "?digest=" else "&digest=");
    try percentEncode(arena, &put_url, desc.digest);

    const res = try r.send(.{
        .method = .PUT,
        .url = put_url.items,
        .body = .{ .file = .{ .path = path, .size = desc.size } },
        .content_type = "application/octet-stream",
    });
    if (res.status != .created) return r.failStatus(res, "uploading a blob");
}

pub fn pushManifest(r: *Registry, tag: []const u8, bytes: []const u8) !void {
    const res = try r.send(.{
        .method = .PUT,
        .url = try r.url("/v2/{s}/manifests/{s}", .{ r.ref.repository, tag }),
        .body = .{ .bytes = bytes },
        .content_type = oci.media_type.manifest,
    });
    if (res.status != .created) return r.failStatus(res, "uploading the manifest");
}

// ---------------------------------------------------------------------------
// HTTP

const Request = struct {
    method: http.Method,
    url: []const u8,
    body: union(enum) {
        none,
        bytes: []const u8,
        file: struct { path: []const u8, size: u64 },
    } = .none,
    content_type: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    /// Where a successful response's body goes; otherwise it is collected
    /// into `Response.body`.
    sink: ?*Io.Writer = null,
};

const Response = struct {
    status: http.Status,
    body: []const u8 = "",
    location: ?[]const u8 = null,
    www_authenticate: ?[]const u8 = null,
};

fn url(r: *Registry, comptime path_fmt: []const u8, args: anytype) ![]const u8 {
    const arena = r.ctx.arena;
    return std.mem.concat(arena, u8, &.{ try r.ref.baseUrl(arena), try std.fmt.allocPrint(arena, path_fmt, args) });
}

/// Sends a request. If the registry asks for authentication, gets a token
/// (or uses basic credentials) and sends it once more.
fn send(r: *Registry, req: Request) !Response {
    const res = try r.follow(req, r.authorization);
    if (res.status != .unauthorized or r.authorization != null) return res;
    const challenge = res.www_authenticate orelse return res;
    try r.authenticate(challenge);
    return r.follow(req, r.authorization);
}

/// Sends a request, following redirects if it has no body. `authorization`
/// only goes to the original host: registries redirect blob downloads to
/// storage services, which must not see the token (and S3 rejects a second
/// kind of authorization).
///
/// Redirects are followed here rather than by std.http.Client because in Zig
/// 0.16 its `privileged_headers`, meant for exactly this, are never sent.
fn follow(r: *Registry, req: Request, authorization: ?[]const u8) !Response {
    var current = req;
    var auth = authorization;
    var redirects: usize = 0;
    while (true) : (redirects += 1) {
        const res = try r.exchange(current, auth);
        if (res.status.class() != .redirect or current.body != .none or current.method.requestHasBody()) return res;
        if (redirects == 5) return fail("{s}: too many redirects", .{req.url});
        const location = res.location orelse return fail("{s}: redirect without a location", .{current.url});
        current.url = try resolveUrl(r.ctx.arena, current.url, location);
        if (!std.ascii.eqlIgnoreCase(authority(current.url), authority(req.url))) auth = null;
    }
}

/// Resolves a Location header against the URL it answered.
fn resolveUrl(arena: Allocator, base: []const u8, location: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, location, "://") != null) return location;
    const scheme_end = std.mem.indexOf(u8, base, "://").? + 3;
    if (std.mem.startsWith(u8, location, "//")) return std.mem.concat(arena, u8, &.{ base[0 .. scheme_end - 2], location });
    const path_start = std.mem.indexOfScalarPos(u8, base, scheme_end, '/') orelse base.len;
    if (std.mem.startsWith(u8, location, "/")) return std.mem.concat(arena, u8, &.{ base[0..path_start], location });
    const query = std.mem.indexOfScalarPos(u8, base, path_start, '?') orelse base.len;
    const dir_end = (std.mem.lastIndexOfScalar(u8, base[0..query], '/') orelse path_start) + 1;
    return std.mem.concat(arena, u8, &.{ base[0..@min(dir_end, base.len)], location });
}

/// The host and port of a URL.
fn authority(u: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, u, "://") orelse return u) + 3;
    const end = std.mem.indexOfAnyPos(u8, u, start, "/?#") orelse u.len;
    return u[start..end];
}

fn exchange(r: *Registry, req: Request, authorization: ?[]const u8) !Response {
    return r.exchangeUnchecked(req, authorization) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => fail("{t} {s}: {t}", .{ req.method, req.url, err }),
    };
}

fn exchangeUnchecked(r: *Registry, req: Request, authorization: ?[]const u8) !Response {
    const io = r.ctx.io;
    const arena = r.ctx.arena;
    var extra: std.ArrayList(http.Header) = .empty;
    if (req.accept) |a| try extra.append(arena, .{ .name = "accept", .value = a });

    var hreq = try r.client.request(req.method, try std.Uri.parse(req.url), .{
        // `follow` handles redirects, so it can decide where the token goes.
        .redirect_behavior = .unhandled,
        .extra_headers = extra.items,
        .headers = .{
            .authorization = if (authorization) |a| .{ .override = a } else .omit,
            .content_type = if (req.content_type) |ct| .{ .override = ct } else .default,
            // Blob bytes must arrive exactly as stored. (Overriding the header
            // rather than `accept_encoding`: with only identity enabled, Zig
            // 0.16's client writes a malformed "accept-encoding" line.)
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer hreq.deinit();

    switch (req.body) {
        .none => if (req.method.requestHasBody()) {
            var empty: [0]u8 = .{};
            try hreq.sendBodyComplete(&empty);
        } else {
            try hreq.sendBodiless();
        },
        .bytes => |bytes| try hreq.sendBodyComplete(try arena.dupe(u8, bytes)),
        .file => |f| {
            var file = try Io.Dir.cwd().openFile(io, f.path, .{});
            defer file.close(io);
            var file_buf: [64 * 1024]u8 = undefined;
            var reader = file.reader(io, &file_buf);
            hreq.transfer_encoding = .{ .content_length = f.size };
            var body_buf: [64 * 1024]u8 = undefined;
            var body = try hreq.sendBodyUnflushed(&body_buf);
            try reader.interface.streamExact64(&body.writer, f.size);
            try body.end();
            try hreq.connection.?.flush();
        },
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try hreq.receiveHead(&redirect_buf);
    var res: Response = .{ .status = response.head.status };
    // Header strings are invalidated once the body is read; keep copies.
    var headers = response.head.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) res.location = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate") and res.www_authenticate == null)
            res.www_authenticate = try arena.dupe(u8, h.value);
    }

    var transfer_buf: [64 * 1024]u8 = undefined;
    const body = response.reader(&transfer_buf);
    if (req.sink != null and res.status.class() == .success) {
        _ = body.streamRemaining(req.sink.?) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            error.WriteFailed => return error.WriteFailed,
        };
    } else {
        res.body = body.allocRemaining(arena, .limited(16 << 20)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
    }
    return res;
}

// ---------------------------------------------------------------------------
// Authentication

fn authenticate(r: *Registry, challenge_text: []const u8) !void {
    const arena = r.ctx.arena;
    const challenge = Challenge.parse(challenge_text) orelse
        return fail("{s} asked for authentication zigsaw doesn't support: {s}", .{ r.ref.host, challenge_text });
    const basic = try r.basicCredentials();

    switch (challenge.scheme) {
        .basic => r.authorization = basic orelse return r.failNeedsLogin(),
        .bearer => {
            const realm = challenge.realm orelse return fail("{s} asked for a token without saying where to get one", .{r.ref.host});
            var token_url: std.ArrayList(u8) = .empty;
            try token_url.appendSlice(arena, realm);
            try token_url.append(arena, if (std.mem.indexOfScalar(u8, realm, '?') == null) '?' else '&');
            if (challenge.service) |service| {
                try token_url.appendSlice(arena, "service=");
                try percentEncode(arena, &token_url, service);
                try token_url.append(arena, '&');
            }
            try token_url.appendSlice(arena, "scope=");
            try percentEncode(arena, &token_url, try std.fmt.allocPrint(arena, "repository:{s}:{s}", .{ r.ref.repository, r.actions }));

            const res = try r.exchange(.{ .method = .GET, .url = token_url.items }, basic);
            if (res.status == .unauthorized or res.status == .forbidden) {
                if (basic == null) return r.failNeedsLogin();
                return fail("{s} refused the credentials in {s} and {s}", .{ r.ref.host, username_var, password_var });
            }
            if (res.status != .ok) return fail("getting a token from {s}: HTTP {d}", .{ realm, @intFromEnum(res.status) });
            const Token = struct { token: ?[]const u8 = null, access_token: ?[]const u8 = null };
            const parsed = std.json.parseFromSliceLeaky(Token, arena, res.body, .{ .ignore_unknown_fields = true }) catch
                return fail("{s} returned a token response zigsaw can't read", .{realm});
            const token = parsed.token orelse parsed.access_token orelse
                return fail("{s} returned no token", .{realm});
            r.authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
        },
    }
}

/// "Basic <base64(user:password)>" from the environment, if set.
fn basicCredentials(r: *Registry) !?[]const u8 {
    const user = r.ctx.env.get(username_var) orelse return null;
    const password = r.ctx.env.get(password_var) orelse return null;
    const plain = try std.fmt.allocPrint(r.ctx.arena, "{s}:{s}", .{ user, password });
    const encoder = std.base64.standard.Encoder;
    const out = try r.ctx.arena.alloc(u8, "Basic ".len + encoder.calcSize(plain.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = encoder.encode(out["Basic ".len..], plain);
    return out;
}

fn failNeedsLogin(r: *Registry) error{Failed} {
    return fail("{f} needs credentials for {s}: set {s} and {s} (for ghcr.io, a GitHub token with the right package scopes)", .{
        r.ref, r.actions, username_var, password_var,
    });
}

/// A WWW-Authenticate challenge, e.g.
/// `Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:a/b:pull"`.
const Challenge = struct {
    scheme: enum { basic, bearer },
    realm: ?[]const u8 = null,
    service: ?[]const u8 = null,

    fn parse(text: []const u8) ?Challenge {
        const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
        var c: Challenge = .{ .scheme = if (std.ascii.eqlIgnoreCase(text[0..space], "bearer"))
            .bearer
        else if (std.ascii.eqlIgnoreCase(text[0..space], "basic"))
            .basic
        else
            return null };

        // Comma-separated key=value parameters; quoted values may contain commas.
        var i = space;
        while (i < text.len) {
            while (i < text.len and (text[i] == ' ' or text[i] == ',')) i += 1;
            const eq = std.mem.indexOfScalarPos(u8, text, i, '=') orelse break;
            const key = std.mem.trim(u8, text[i..eq], " ");
            var value: []const u8 = undefined;
            if (eq + 1 < text.len and text[eq + 1] == '"') {
                const close = std.mem.indexOfScalarPos(u8, text, eq + 2, '"') orelse return null;
                value = text[eq + 2 .. close];
                i = close + 1;
            } else {
                const end = std.mem.indexOfScalarPos(u8, text, eq + 1, ',') orelse text.len;
                value = std.mem.trim(u8, text[eq + 1 .. end], " ");
                i = end;
            }
            if (std.ascii.eqlIgnoreCase(key, "realm")) c.realm = value;
            if (std.ascii.eqlIgnoreCase(key, "service")) c.service = value;
        }
        return c;
    }
};

/// Explains a failed request, using the registry's error message if it sent one.
fn failStatus(r: *Registry, res: Response, what: []const u8) error{Failed} {
    const code = @intFromEnum(res.status);
    const has_credentials = r.ctx.env.get(username_var) != null and r.ctx.env.get(password_var) != null;
    switch (res.status) {
        .unauthorized, .forbidden => return if (has_credentials)
            fail("{s} for {f}: access denied (HTTP {d}); the registry refused the credentials in {s} and {s}, or they don't allow {s}", .{
                what, r.ref, code, username_var, password_var, r.actions,
            })
        else
            fail("{s} for {f}: access denied (HTTP {d}); for private images and pushing, set {s} and {s}", .{
                what, r.ref, code, username_var, password_var,
            }),
        .not_found => return fail("{s} for {f}: not found", .{ what, r.ref }),
        else => {},
    }
    const Errors = struct { errors: []const struct { code: []const u8 = "", message: []const u8 = "" } };
    if (std.json.parseFromSliceLeaky(Errors, r.ctx.arena, res.body, .{ .ignore_unknown_fields = true })) |e| {
        if (e.errors.len > 0) return fail("{s} for {f}: HTTP {d} {s}: {s}", .{ what, r.ref, code, e.errors[0].code, e.errors[0].message });
    } else |_| {}
    return fail("{s} for {f}: HTTP {d}", .{ what, r.ref, code });
}

/// Appends `s` percent-encoded for use in a URL query.
fn percentEncode(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => try out.append(arena, c),
        else => try out.print(arena, "%{X:0>2}", .{c}),
    };
}

test "Reference.parse" {
    const hex = "07bb1e5b095b00d68a695481f9240879f33c5724b40aa2308f999d54ed78f075";
    const r1 = try Reference.parse("ghcr.io/owner/tools/node:24.21.0");
    try std.testing.expectEqualStrings("ghcr.io", r1.host);
    try std.testing.expectEqualStrings("owner/tools/node", r1.repository);
    try std.testing.expectEqualStrings("24.21.0", r1.tag.?);
    try std.testing.expectEqualStrings("24.21.0", r1.manifestRef());

    const r2 = try Reference.parse("localhost:5000/busybox@sha256:" ++ hex);
    try std.testing.expectEqualStrings("localhost:5000", r2.host);
    try std.testing.expect(r2.tag == null);
    try std.testing.expectEqualStrings("sha256:" ++ hex, r2.manifestRef());

    try std.testing.expectEqualStrings("latest", (try Reference.parse("docker.io/library/alpine")).manifestRef());

    for ([_][]const u8{ "node", "owner/node:1", "ghcr.io/Owner/node", "ghcr.io/owner/node:", "ghcr.io/", "ghcr.io/a//b", "ghcr.io/a@sha256:xyz" }) |bad| {
        try std.testing.expectError(error.InvalidReference, Reference.parse(bad));
    }
}

test "Reference.baseUrl" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("https://ghcr.io", try (try Reference.parse("ghcr.io/a/b")).baseUrl(arena));
    try std.testing.expectEqualStrings("http://localhost:5000", try (try Reference.parse("localhost:5000/b")).baseUrl(arena));
    try std.testing.expectEqualStrings("https://registry-1.docker.io", try (try Reference.parse("docker.io/library/alpine")).baseUrl(arena));
}

test "Challenge.parse" {
    const c = Challenge.parse("Bearer realm=\"https://ghcr.io/token\",service=\"ghcr.io\",scope=\"repository:a/b:pull,push\"").?;
    try std.testing.expectEqual(.bearer, c.scheme);
    try std.testing.expectEqualStrings("https://ghcr.io/token", c.realm.?);
    try std.testing.expectEqualStrings("ghcr.io", c.service.?);
    try std.testing.expectEqual(.basic, Challenge.parse("Basic realm=\"zot\"").?.scheme);
    try std.testing.expect(Challenge.parse("Negotiate") == null);
}

test resolveUrl {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "https://ghcr.io/v2/a/b/blobs/sha256:1?x=1";
    try std.testing.expectEqualStrings("https://cdn.example/x", try resolveUrl(arena, base, "https://cdn.example/x"));
    try std.testing.expectEqualStrings("https://cdn.example/x", try resolveUrl(arena, base, "//cdn.example/x"));
    try std.testing.expectEqualStrings("https://ghcr.io/v2/other", try resolveUrl(arena, base, "/v2/other"));
    try std.testing.expectEqualStrings("https://ghcr.io/v2/a/b/blobs/next", try resolveUrl(arena, base, "next"));
    try std.testing.expectEqualStrings("ghcr.io", authority(base));
    try std.testing.expectEqualStrings("localhost:5000", authority("http://localhost:5000"));
}

test percentEncode {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(u8) = .empty;
    try percentEncode(arena_state.allocator(), &out, "repository:a/b:pull,push");
    try std.testing.expectEqualStrings("repository%3Aa%2Fb%3Apull%2Cpush", out.items);
}
