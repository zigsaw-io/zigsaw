//! Lazy pulling: `zigsaw pull --lazy` installs an app before its indexed
//! (eStargz) layers are downloaded. Each such layer's deployment starts as a
//! Cloud Files sync root: a placeholder for each of its files, which Windows
//! asks a helper process for as something first reads it. The helper
//! (LazyHelper.zig, `zigsaw lazy-helper`) serves those reads from the
//! registry, chunk by chunk, each checked against the layer's TOC, while it
//! downloads the whole blob. Once the blob is in the store and checked, and
//! no run is using the deployment, the helper unpacks it as a full pull would
//! and swaps it in for the placeholders. From then on nothing is different.
//! See docs/experiment-cloud-files.md for why it's a bridge, not a way of
//! keeping apps.
//!
//! What a lazy layer has, while it's lazy, in the store:
//!   lazy\<hex>\layer.json   the layer's descriptor and repository
//!   lazy\<hex>\tail         the blob's last bytes, with its TOC, as pull fetched them
//!   lazy\<hex>\blob.part    the download so far
//!   lazy\<hex>\state.json   what the helper is doing, for `list`
//!   lazy\<hex>\log          the helper's messages: each fetch, and what failed
//!   lazy\<hex>.helper.lock  held by the helper while it runs; beside the folder,
//!                           as the helper deletes that before it ends
//!   lazy\<hex>.start.lock   held while a helper is being started
//!   lazy\zigsaw-<hash>.exe  the copy of zigsaw that helpers run, so that
//!                           zigsaw.exe can be replaced while they do

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const RemoteBlob = @import("RemoteBlob.zig");
const BlobReader = @import("BlobReader.zig");
const cloudfiles = @import("cloudfiles.zig");
const Store = @import("Store.zig");
const format = @import("format.zig");
const oci = @import("oci.zig");
const process = @import("process.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

/// What `layer.json` holds.
pub const Meta = struct {
    host: []const u8,
    repository: []const u8,
    layer: oci.Descriptor,
};

/// What `state.json` holds.
pub const State = struct {
    phase: []const u8,
    downloaded: u64 = 0,
    size: u64 = 0,
    pid: u32 = 0,
    failures: u32 = 0,
    @"error": ?[]const u8 = null,
};

pub fn dirPath(store: Store, arena: Allocator, hex: []const u8) ![]u8 {
    return store.path(arena, &.{ "lazy", hex });
}

pub fn filePath(store: Store, arena: Allocator, hex: []const u8, name: []const u8) ![]u8 {
    return store.path(arena, &.{ "lazy", hex, name });
}

/// lazy\<hex>.<which>.lock: "helper" or "start".
pub fn lockPath(store: Store, arena: Allocator, hex: []const u8, which: []const u8) ![]u8 {
    return store.path(arena, &.{ "lazy", try std.fmt.allocPrint(arena, "{s}.{s}.lock", .{ hex, which }) });
}

/// Whether the layer's deployment is still lazy: placeholders, or a helper
/// on its way to making them.
pub fn isLazy(store: Store, arena: Allocator, hex: []const u8) !bool {
    return Store.exists(store.io, try dirPath(store, arena, hex));
}

pub fn readState(store: Store, arena: Allocator, hex: []const u8) ?State {
    const bytes = Io.Dir.cwd().readFileAlloc(store.io, filePath(store, arena, hex, "state.json") catch return null, arena, .limited(64 << 10)) catch return null;
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{ .ignore_unknown_fields = true }) catch null;
}

pub fn writeState(store: Store, arena: Allocator, hex: []const u8, state: State) !void {
    const tmp = try filePath(store, arena, hex, "state.json.tmp");
    try Io.Dir.cwd().writeFile(store.io, .{ .sub_path = tmp, .data = try oci.toJson(arena, state) });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), try filePath(store, arena, hex, "state.json"), store.io);
}

pub fn readMeta(store: Store, arena: Allocator, hex: []const u8) !Meta {
    const bytes = try Io.Dir.cwd().readFileAlloc(store.io, try filePath(store, arena, hex, "layer.json"), arena, .limited(1 << 20));
    return std.json.parseFromSliceLeaky(Meta, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// What `list` says of an app with a layer that's still lazy: null if none is.
pub fn describe(store: Store, arena: Allocator, manifest: oci.Manifest) !?[]const u8 {
    for (manifest.layers) |l| {
        const hex = oci.digestHex(l.digest) orelse continue;
        if (!try isLazy(store, arena, hex)) continue;
        const s = readState(store, arena, hex) orelse return "(fetching)";
        const pct = if (s.size == 0) 0 else s.downloaded * 100 / s.size;
        const live = try Store.isLocked(store.io, try lockPath(store, arena, hex, "helper"));
        if (std.mem.eql(u8, s.phase, "unpacking") or std.mem.eql(u8, s.phase, "swapping")) return "(unpacking)";
        if (!live or std.mem.eql(u8, s.phase, "paused"))
            return try std.fmt.allocPrint(arena, "(paused at {d}%{s}{s}; runs go on)", .{ pct, if (s.@"error" != null) ": " else "", s.@"error" orelse "" });
        return try std.fmt.allocPrint(arena, "(downloading {d}%)", .{pct});
    }
    return null;
}

/// The smallest layer pulled lazily: below it, a whole download takes
/// about as long as the requests would. ZIGSAW_TEST_LAZY_MIN lowers it.
fn minSize(ctx: *Context) u64 {
    if (ctx.env.get("ZIGSAW_TEST_LAZY_MIN")) |v| return std.fmt.parseInt(u64, v, 10) catch 32 << 20;
    return 32 << 20;
}

/// Whether `--lazy` makes a layer the store lacks lazy: an indexed one of
/// some size. What else it takes is known only from its index (see `prepare`).
pub fn eligible(ctx: *Context, desc: oci.Descriptor) bool {
    const f = format.Format.ofDescriptor(desc) orelse return false;
    return f.indexed() and desc.size >= minSize(ctx);
}

pub const Prepared = enum {
    /// Its deployment is placeholders, served by a helper.
    lazy,
    /// It's to be downloaded as without --lazy; why was said.
    whole,
};

/// Makes the layer's deployment placeholders, served by a new helper, for a
/// pull that has agreed to the image: its TOC fetched and checked against
/// the descriptor, as the deployment comes from it alone. Falls back to a
/// whole download, with a note, where that isn't possible.
pub fn prepare(ctx: *Context, registry: *Registry, desc: oci.Descriptor) !Prepared {
    const store = ctx.store;
    const arena = ctx.arena;
    const io = ctx.io;
    const hex = oci.digestHex(desc.digest).?;
    const short = oci.shortDigest(desc.digest);
    if (try Store.exists(io, try store.deployPath(arena, desc.digest))) {
        // Placeholders already, from another pull, or files whose blob went.
        if (try isLazy(store, arena, hex)) return .lazy;
        return .whole;
    }
    const blob = try RemoteBlob.open(ctx, registry, desc);
    defer blob.close();
    const index = format.openIndex(ctx.gpa, desc, blob.source()) catch |err| switch (err) {
        error.RangeIgnored => {
            note("  layer {s}: {f} sends blobs only whole, so it's downloaded whole", .{ short, registry.ref });
            return .whole;
        },
        else => |e| return e,
    };
    defer index.deinit();
    try format.checkDeployable(desc, index);
    for (index.files) |f| for (f.chunks) |c| if (c.digest == null) {
        note("  layer {s}: its TOC doesn't give every chunk's digest, so it's downloaded whole", .{short});
        return .whole;
    };

    const dir = try dirPath(store, arena, hex);
    try Io.Dir.cwd().createDirPath(io, dir);
    errdefer Store.deleteTree(io, arena, dir) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try filePath(store, arena, hex, "tail"), .data = blob.tail.? });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try filePath(store, arena, hex, "layer.json"), .data = try oci.toJson(arena, Meta{
        .host = registry.ref.host,
        .repository = registry.ref.repository,
        .layer = desc,
    }) });
    try writeState(store, arena, hex, .{ .phase = "starting", .size = desc.size });
    switch (try startHelper(ctx, hex)) {
        .serving => {},
        .unsupported => |why| {
            note("  layer {s}: {s}, so it's downloaded whole", .{ short, why });
            try Store.deleteTree(io, arena, dir);
            return .whole;
        },
    }
    // For what installing reads of the layer's files, as long as this
    // process lasts: their headers, from the index (see `headerOf`).
    const reader = try BlobReader.init(ctx.gpa, ctx, registry.ref, desc.digest, desc.size, blob.tail.?, .{ .clients = 2, .slots = 8 });
    try sessions.append(arena, .{
        .root = try store.deployPath(arena, desc.digest),
        .index = try format.openIndex(ctx.gpa, desc, reader.source()),
    });
    return .lazy;
}

/// A layer this process made lazy, whose index it keeps.
const Session = struct {
    root: []const u8,
    index: *format.Index,
};
var sessions: std.ArrayList(Session) = .empty;

/// The first bytes of `path`, a file of a layer this process made lazy that
/// nothing has read yet, from the layer's index, into `buf`: what telling a
/// GUI program from a console one needs, without the whole file fetched, as
/// opening it would. Null for any other file, which is to be read as usual.
pub fn headerOf(gpa: Allocator, path: []const u8, buf: []u8) ?[]const u8 {
    if (sessions.items.len == 0) return null;
    const path_w = win32.wide(gpa, path) catch return null;
    defer gpa.free(path_w);
    const attributes = win32.GetFileAttributesW(path_w);
    if (attributes == win32.INVALID_FILE_ATTRIBUTES or attributes & cloudfiles.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS == 0) return null;
    for (sessions.items) |s| {
        if (path.len <= s.root.len + 1 or !std.ascii.eqlIgnoreCase(path[0..s.root.len], s.root) or path[s.root.len] != '\\') continue;
        const name = gpa.dupe(u8, path[s.root.len + 1 ..]) catch return null;
        defer gpa.free(name);
        std.mem.replaceScalar(u8, name, '\\', '/');
        const f = s.index.lookup(name) orelse return null;
        if (f.chunks.len == 0) return null;
        var scratch: format.Index.Scratch = .{};
        defer scratch.deinit(gpa);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        s.index.readChunk(gpa, &scratch, f.chunks[0], &out.writer) catch return null;
        const n = @min(buf.len, out.written().len);
        @memcpy(buf[0..n], out.written()[0..n]);
        return buf[0..n];
    }
    return null;
}

/// Makes sure each of these layers that's still lazy has a helper, before a
/// run, build or update uses them: one ends with a reboot, or with the job
/// of whatever started it.
pub fn ensureServed(ctx: *Context, layers: []const oci.Descriptor) !void {
    for (layers) |l| {
        const hex = oci.digestHex(l.digest) orelse continue;
        if (!try isLazy(ctx.store, ctx.arena, hex)) continue;
        if (try helperAlive(ctx.store, ctx.arena, hex)) continue;
        switch (try startHelper(ctx, hex)) {
            .serving => {},
            .unsupported => |why| return fail("layer {s} is still being fetched, and can't be any more: {s}; `zigsaw rm` the app and pull it again", .{ oci.shortDigest(l.digest), why }),
        }
    }
}

pub fn helperAlive(store: Store, arena: Allocator, hex: []const u8) !bool {
    return Store.isLocked(store.io, try lockPath(store, arena, hex, "helper"));
}

/// What starting a helper came to.
pub const Started = union(enum) {
    /// Ready: the placeholders are there and served.
    serving,
    /// This store's volume can't have sync roots, as a Dev Drive can't.
    unsupported: []const u8,
};

/// Exit codes of `zigsaw lazy-helper`.
pub const exit_unsupported = 3;

/// The name of one of a layer's helper's events: "ready" or "stop".
pub fn eventName(arena: Allocator, store: Store, hex: []const u8, which: []const u8) ![:0]u16 {
    const lower = try std.ascii.allocLowerString(arena, std.mem.trimEnd(u8, store.fullRoot(arena), "\\/"));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lower, &digest, .{});
    return win32.wide(arena, try std.fmt.allocPrint(arena, "Local\\zigsaw-{x}-{s}-{s}", .{ digest[0..8], hex[0..16], which }));
}

/// Starts the layer's helper, unless one has started meanwhile, and waits
/// until it serves the placeholders, or ends.
pub fn startHelper(ctx: *Context, hex: []const u8) !Started {
    const store = ctx.store;
    const arena = ctx.arena;
    const io = ctx.io;
    // One starter at a time: a second finds the first's helper.
    const starting = try Store.openLock(io, try lockPath(store, arena, hex, "start"), .exclusive, .wait);
    defer starting.release(io);
    // Done meanwhile: the deployment is a plain one now.
    if (!try isLazy(store, arena, hex)) return .serving;
    if (try helperAlive(store, arena, hex)) return .serving;

    const ready = win32.CreateEventW(null, win32.TRUE, win32.FALSE, try eventName(arena, store, hex, "ready")) orelse
        return win32.lastErrorFail("CreateEventW");
    defer _ = win32.CloseHandle(ready);
    const exe = try helperExe(ctx);
    var line: std.ArrayList(u8) = .empty;
    try process.appendQuoted(arena, &line, exe);
    try line.appendSlice(arena, " lazy-helper ");
    try process.appendQuoted(arena, &line, store.fullRoot(arena));
    try line.append(arena, ' ');
    try line.appendSlice(arena, hex);
    const child = try process.startDetached(arena, exe, line.items, store.fullRoot(arena));
    defer _ = win32.CloseHandle(child.process);
    if (!child.broke_away)
        note("note: this zigsaw is in a job that keeps what it starts, so fetching layer {s} goes on only while that lasts; the app's next run starts it again", .{hex[0..12]});

    // A TOC of many thousand files takes a second or two to make placeholders of.
    const handles = [2]win32.HANDLE{ ready, child.process };
    switch (win32.WaitForMultipleObjects(2, &handles, win32.FALSE, 120_000)) {
        win32.WAIT_OBJECT_0 => return .serving,
        win32.WAIT_OBJECT_0 + 1 => {
            var code: win32.DWORD = 1;
            _ = win32.GetExitCodeProcess(child.process, &code);
            if (code == exit_unsupported)
                return .{ .unsupported = try std.fmt.allocPrint(arena, "the store's volume can't have Cloud Files placeholders ({s})", .{volumeOf(store.fullRoot(arena))}) };
            // It may have found nothing left to do, or ended as another
            // started, which then serves.
            if (!try isLazy(store, arena, hex) or try helperAlive(store, arena, hex)) return .serving;
            return fail("fetching layer {s} didn't start: {s}", .{ hex[0..12], lastLogLine(store, arena, hex) });
        },
        else => return fail("fetching layer {s} didn't start within two minutes: {s}", .{ hex[0..12], lastLogLine(store, arena, hex) }),
    }
}

fn volumeOf(path: []const u8) []const u8 {
    return if (path.len >= 2 and path[1] == ':') path[0..2] else path;
}

/// The helper's last message, for an error that has nothing better.
pub fn lastLogLine(store: Store, arena: Allocator, hex: []const u8) []const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(store.io, filePath(store, arena, hex, "log") catch return "no log", arena, .limited(1 << 20)) catch return "no log";
    const trimmed = std.mem.trimEnd(u8, bytes, "\r\n ");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return if (trimmed.len == 0) "no log" else trimmed[start..];
}

/// How many fetches the helper has said failed: `run` compares it before and
/// after, to say why an app failed when it would only say BAD_EXE_FORMAT.
pub fn failuresSoFar(store: Store, arena: Allocator, hex: []const u8) u32 {
    const s = readState(store, arena, hex) orelse return 0;
    return s.failures;
}

/// The failed fetches the log has after its first `skip` such lines.
pub fn failedFetches(store: Store, arena: Allocator, hex: []const u8, skip: u32) ![]const []const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(store.io, try filePath(store, arena, hex, "log"), arena, .limited(16 << 20)) catch return &.{};
    var found: std.ArrayList([]const u8) = .empty;
    var seen: u32 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "fetch failed: ")) continue;
        seen += 1;
        if (seen > skip) try found.append(arena, line["fetch failed: ".len..]);
    }
    return found.items;
}

/// Stops the layer's helper, if it runs, and deletes what the layer had in
/// lazy\. The deployment is the caller's to delete: see
/// `Store.deleteDeployment`, which holds its lock exclusively, so no run uses
/// what the helper served.
pub fn stop(store: Store, arena: Allocator, hex: []const u8) void {
    const io = store.io;
    const dir = dirPath(store, arena, hex) catch return;
    if (!(Store.exists(io, dir) catch false)) return;
    const lock = lockPath(store, arena, hex, "helper") catch return;
    if (Store.isLocked(io, lock) catch false) {
        if (eventName(arena, store, hex, "stop")) |name| {
            if (win32.OpenEventW(win32.EVENT_MODIFY_STATE, win32.FALSE, name)) |event| {
                _ = win32.SetEvent(event);
                _ = win32.CloseHandle(event);
            }
        } else |_| {}
        var waited: u32 = 0;
        while (waited < 15_000 and (Store.isLocked(io, lock) catch false)) : (waited += 50) win32.Sleep(50);
        if (Store.isLocked(io, lock) catch false) {
            if (readState(store, arena, hex)) |s| if (s.pid != 0) {
                if (win32.OpenProcess(win32.PROCESS_TERMINATE | win32.SYNCHRONIZE, win32.FALSE, s.pid)) |p| {
                    _ = win32.TerminateProcess(p, 1);
                    _ = win32.WaitForSingleObject(p, 5000);
                    _ = win32.CloseHandle(p);
                }
            };
        }
    }
    Store.deleteTree(io, arena, dir) catch |err|
        note("warning: couldn't delete all of {s} ({t}); `zigsaw prune` will retry", .{ dir, err });
}

/// The copy of this zigsaw that helpers run, in lazy\, named by its contents
/// so that one running is never replaced.
fn helperExe(ctx: *Context) ![]const u8 {
    const io = ctx.io;
    const arena = ctx.arena;
    const self = try win32.selfExePath(arena);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, self, arena, .limited(64 << 20));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const dest = try ctx.store.path(arena, &.{ "lazy", try std.fmt.allocPrint(arena, "zigsaw-{x}.exe", .{hash[0..8]}) });
    if (try Store.exists(io, dest)) return dest;
    const tmp = try ctx.store.tmpPath(arena, "helper");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
    Io.Dir.rename(.cwd(), tmp, .cwd(), dest, io) catch |err| {
        // Another zigsaw put it there first.
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        if (!try Store.exists(io, dest)) return err;
    };
    return dest;
}

/// What `prune` deletes in lazy\: what's left of layers whose deployment is
/// gone and whose helper isn't running, and copies of zigsaw that no helper
/// runs. Returns how many entries went.
pub fn prune(store: Store, arena: Allocator, current_exe_name: ?[]const u8) !usize {
    const io = store.io;
    const lazy_dir = try store.path(arena, &.{"lazy"});
    var dir = Io.Dir.cwd().openDir(io, lazy_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
    var deleted: usize = 0;
    for (names.items) |name| {
        const p = try std.fs.path.join(arena, &.{ lazy_dir, name });
        if (oci.isSha256Hex(name)) {
            if (try Store.exists(io, try store.deployPath(arena, try std.fmt.allocPrint(arena, "sha256:{s}", .{name})))) continue;
            if (try helperAlive(store, arena, name)) continue;
            Store.deleteTree(io, arena, p) catch continue;
            deleted += 1;
        } else if (std.mem.endsWith(u8, name, ".lock")) {
            // <hex>.helper.lock and <hex>.start.lock, once their layer's gone.
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse continue;
            if (Store.exists(io, try std.fs.path.join(arena, &.{ lazy_dir, name[0..dot] })) catch true) continue;
            if (Store.isLocked(io, p) catch true) continue;
            Io.Dir.cwd().deleteFile(io, p) catch continue;
            deleted += 1;
        } else if (std.mem.startsWith(u8, name, "zigsaw-") and std.mem.endsWith(u8, name, ".exe")) {
            if (current_exe_name) |cur| if (std.mem.eql(u8, cur, name)) continue;
            // A running copy can't be deleted, which is what tells.
            Io.Dir.cwd().deleteFile(io, p) catch continue;
            deleted += 1;
        }
    }
    return deleted;
}

test "event names differ by store and layer, and fit Windows' limit" {
    const arena = std.testing.allocator;
    var a = std.heap.ArenaAllocator.init(arena);
    defer a.deinit();
    const hex = "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef";
    const s1: Store = .{ .io = std.testing.io, .root = "C:\\Users\\u\\AppData\\Local\\zigsaw" };
    const s2: Store = .{ .io = std.testing.io, .root = "D:\\other" };
    const n1 = try eventName(a.allocator(), s1, hex, "ready");
    const n2 = try eventName(a.allocator(), s2, hex, "ready");
    try std.testing.expect(!std.mem.eql(u16, n1, n2));
    try std.testing.expect(n1.len < 260);
}
