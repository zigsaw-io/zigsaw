//! `zigsaw lazy-helper <store> <hex>`: the process behind a lazy layer (see
//! lazy.zig). It makes the layer's deployment placeholders, or connects to
//! them, and serves what Windows asks for from the blob, each chunk checked
//! against the TOC; downloads the whole blob meanwhile, and checks it; and,
//! once no run uses the deployment, unpacks the blob and swaps the result in.
//! One per layer: Windows lets one process provide for a sync root. It must
//! not open the placeholders itself (Windows refuses its own process, error
//! 395), which is why it isn't `zigsaw run`.
//!
//! Its stderr is lazy\<hex>\log, so what `note` and `fail` say goes there.
//! Exit codes: 0 done or stopped, 1 failed (the log says why), 3 the
//! store's volume can't have sync roots.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const BlobReader = @import("BlobReader.zig");
const Context = @import("Context.zig");
const Registry = @import("Registry.zig");
const Store = @import("Store.zig");
const acl = @import("acl.zig");
const cloudfiles = @import("cloudfiles.zig");
const format = @import("format.zig");
const lazy = @import("lazy.zig");
const oci = @import("oci.zig");
const win32 = @import("win32.zig");
const fail = Context.fail;
const note = Context.note;

const Helper = struct {
    ctx: *Context,
    gpa: Allocator,
    hex: []const u8,
    desc: oci.Descriptor,
    root: []const u8,
    index: *format.Index,
    reader: *BlobReader,
    blob_path: []const u8,
    part_path: []const u8,
    conn: ?cloudfiles.Connection = null,

    inflight: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),
    downloaded: std.atomic.Value(u64) = .init(0),
    complete: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    /// The download's last failure, for state.json; empty when it's going.
    error_lock: win32.SRWLOCK = .{},
    error_buf: [200]u8 = undefined,
    error_len: usize = 0,
    /// The unpacked blob, waiting for the deployment to be free.
    unpacked: ?[]const u8 = null,
    /// Held on the unpacked tree's folder in tmp, so that prune leaves it.
    unpacked_lock: ?Store.Lock = null,
    /// When the download last got anywhere, or the helper started.
    progress_at: std.atomic.Value(i64) = .init(0),
    /// Tests' hooks: ZIGSAW_TEST_LAZY_GATE, a file the download waits on while
    /// it's there; ZIGSAW_TEST_LAZY_FAIL, a name whose fetches fail.
    test_gate: ?[]const u8 = null,
    test_fail: ?[]const u8 = null,

    fn setError(h: *Helper, comptime fmt: []const u8, args: anytype) void {
        win32.AcquireSRWLockExclusive(&h.error_lock);
        defer win32.ReleaseSRWLockExclusive(&h.error_lock);
        const text: []const u8 = std.fmt.bufPrint(&h.error_buf, fmt, args) catch "";
        h.error_len = text.len;
    }

    fn errorText(h: *Helper, arena: Allocator) ?[]const u8 {
        win32.AcquireSRWLockExclusive(&h.error_lock);
        defer win32.ReleaseSRWLockExclusive(&h.error_lock);
        if (h.error_len == 0) return null;
        return arena.dupe(u8, h.error_buf[0..h.error_len]) catch null;
    }
};

fn nowSeconds() i64 {
    var ft: i64 = 0;
    win32.GetSystemTimeAsFileTime(&ft);
    return @divTrunc(ft, 10_000_000);
}

pub fn main(ctx: *Context, hex: []const u8) !u32 {
    const store = ctx.store;
    const arena = ctx.arena;
    const io = ctx.io;
    const gpa = std.heap.smp_allocator;
    if (!oci.isSha256Hex(hex)) return fail("lazy-helper: \"{s}\" isn't a layer's digest", .{hex});
    // Held until this process ends, however it ends.
    _ = try Store.tryLock(io, try lazy.lockPath(store, arena, hex, "helper"), .exclusive) orelse return 0;
    if (!try lazy.isLazy(store, arena, hex)) return 0;
    try toLog(arena, try lazy.filePath(store, arena, hex, "log"));
    note("helper {d}, zigsaw {s}, for layer {s}", .{ win32.GetCurrentProcessId(), @import("options").version, hex[0..12] });

    const meta = lazy.readMeta(store, arena, hex) catch |err| return fail("reading layer.json: {t}", .{err});
    const desc = meta.layer;
    if (!std.mem.eql(u8, oci.digestHex(desc.digest) orelse "", hex)) return fail("layer.json names another layer", .{});
    const tail = Io.Dir.cwd().readFileAlloc(io, try lazy.filePath(store, arena, hex, "tail"), gpa, .limited(64 << 20)) catch |err|
        return fail("reading the blob's tail: {t}", .{err});
    if (tail.len > desc.size) return fail("the blob's tail is longer than the blob", .{});
    const reader = try BlobReader.init(gpa, ctx, .{ .host = meta.host, .repository = meta.repository }, desc.digest, desc.size, tail, .{});
    const blob_path = try store.blobPath(arena, hex);
    const part_path = try lazy.filePath(store, arena, hex, "blob.part");

    var h: Helper = .{
        .ctx = ctx,
        .gpa = gpa,
        .hex = hex,
        .desc = desc,
        .root = try store.deployPath(arena, desc.digest),
        .index = undefined,
        .reader = reader,
        .blob_path = blob_path,
        .part_path = part_path,
    };
    h.progress_at.store(nowSeconds(), .monotonic);
    if (try Store.exists(io, blob_path)) {
        reader.setHave(blob_path, desc.size);
        h.downloaded.store(desc.size, .monotonic);
        h.complete.store(true, .release);
    }
    // The TOC, checked against the descriptor once more: the tail is a file
    // in the store, which anything of the user's could have changed.
    h.index = format.openIndex(gpa, desc, reader.source()) catch |err| return fail("the layer's index: {t}", .{err});
    try format.checkDeployable(desc, h.index);

    if (try finishedAlready(&h)) return 0;
    h.test_gate = ctx.env.get("ZIGSAW_TEST_LAZY_GATE");
    h.test_fail = ctx.env.get("ZIGSAW_TEST_LAZY_FAIL");
    // Tests' hook: as on a volume that can't have sync roots.
    const refuse = ctx.env.get("ZIGSAW_TEST_LAZY_REFUSE") != null;
    const made = (if (refuse) error.Unsupported else connectRoot(&h)) catch |err| switch (err) {
        error.Unsupported => {
            note("the store's volume can't have sync roots", .{});
            lazy.writeState(store, arena, hex, .{ .phase = "unsupported", .size = desc.size }) catch {};
            return lazy.exit_unsupported;
        },
        else => |e| return e,
    };
    note("serving {d} files{s}", .{ h.index.files.len, if (made > 0) ", placeholders made" else "" });
    // Before ready: whoever started this reads who serves, as `rm` does to
    // end it if it won't stop.
    try lazy.writeState(store, arena, hex, .{
        .phase = if (h.complete.load(.acquire)) "downloaded" else "serving",
        .downloaded = h.downloaded.load(.monotonic),
        .size = desc.size,
        .pid = win32.GetCurrentProcessId(),
    });

    const stop = win32.CreateEventW(null, win32.TRUE, win32.FALSE, try lazy.eventName(arena, store, hex, "stop")) orelse
        return win32.lastErrorFail("CreateEventW");
    if (win32.OpenEventW(win32.EVENT_MODIFY_STATE, win32.FALSE, try lazy.eventName(arena, store, hex, "ready"))) |ready| {
        _ = win32.SetEvent(ready);
        _ = win32.CloseHandle(ready);
    }

    if (!h.complete.load(.acquire)) {
        const t = try std.Thread.spawn(.{}, download, .{&h});
        t.detach();
    }

    // Once a second: say what's going on, and swap when it's time.
    var tick: std.heap.ArenaAllocator = .init(gpa);
    defer tick.deinit();
    while (true) {
        _ = tick.reset(.retain_capacity);
        const t = tick.allocator();
        if (win32.WaitForSingleObject(stop, 1000) == win32.WAIT_OBJECT_0) {
            h.stopping.store(true, .release);
            if (h.conn) |c| c.disconnect();
            note("stopped", .{});
            return 0;
        }
        const complete = h.complete.load(.acquire);
        lazy.writeState(store, t, hex, .{
            .phase = if (h.unpacked != null) "unpacking" else if (complete) "downloaded" else "serving",
            .downloaded = h.downloaded.load(.monotonic),
            .size = desc.size,
            .pid = win32.GetCurrentProcessId(),
            .failures = h.failures.load(.monotonic),
            .@"error" = h.errorText(t),
        }) catch {};
        if (complete) {
            if (try swap(&h, t)) {
                note("swapped in the unpacked layer; done", .{});
                return 0;
            }
            continue;
        }
        // Nothing got anywhere for ten minutes, and nothing uses the
        // deployment: the next run starts a helper again.
        if (nowSeconds() - h.progress_at.load(.monotonic) > 600 and !try store.deploymentInUse(t, desc.digest)) {
            lazy.writeState(store, t, hex, .{
                .phase = "paused",
                .downloaded = h.downloaded.load(.monotonic),
                .size = desc.size,
                .failures = h.failures.load(.monotonic),
                .@"error" = h.errorText(t),
            }) catch {};
            note("paused: no progress for ten minutes, and no run", .{});
            if (h.conn) |c| c.disconnect();
            return 0;
        }
    }
}

/// Points stderr at the log, appending.
fn toLog(arena: Allocator, path: []const u8) !void {
    const FILE_APPEND_DATA: win32.DWORD = 0x4;
    const OPEN_ALWAYS: win32.DWORD = 4;
    const h = win32.CreateFileW(try win32.wide(arena, path), FILE_APPEND_DATA | win32.SYNCHRONIZE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, OPEN_ALWAYS, 0, null);
    if (h == win32.INVALID_HANDLE_VALUE) return win32.lastErrorFail("opening the log");
    _ = win32.SetStdHandle(win32.STD_ERROR_HANDLE, h);
}

/// A helper started after the swap's last step but one finds the unpacked
/// layer in place: nothing's left but the layer's folder in lazy\.
fn finishedAlready(h: *Helper) !bool {
    const io = h.ctx.io;
    if (!h.complete.load(.acquire)) return false;
    if (!try Store.exists(io, h.root) or cloudfiles.isSyncRoot(h.gpa, h.root)) return false;
    note("the layer is unpacked already", .{});
    try Store.deleteTree(io, h.ctx.arena, try lazy.dirPath(h.ctx.store, h.ctx.arena, h.hex));
    return true;
}

/// Makes the root, or finds it, and connects to it. Returns how many
/// placeholders were made: none when they were there already.
fn connectRoot(h: *Helper) !usize {
    const io = h.ctx.io;
    const gpa = h.gpa;
    var fresh = false;
    if (!try Store.exists(io, h.root)) {
        try Io.Dir.cwd().createDirPath(io, h.root);
        try cloudfiles.register(gpa, h.root, h.hex, false);
        fresh = true;
    } else if (!cloudfiles.isSyncRoot(gpa, h.root)) {
        // Windows forgot it (a reboot?), or a helper ended before registering.
        if (try isEmptyDir(io, h.root)) {
            try cloudfiles.register(gpa, h.root, h.hex, false);
            fresh = true;
        } else {
            note("registering the deployment again", .{});
            try cloudfiles.register(gpa, h.root, h.hex, true);
        }
    }
    h.conn = try cloudfiles.connect(gpa, h.root, h, onFetch, onCancel);
    return if (fresh) makePlaceholders(h) else 0;
}

fn isEmptyDir(io: Io, path: []const u8) !bool {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    return (try it.next(io)) == null;
}

fn depth(name: []const u8) usize {
    if (name.len == 0) return 0;
    return std.mem.count(u8, name, "/") + 1;
}

/// A placeholder for each of the layer's directories and files, a
/// directory's children at once, parents first.
fn makePlaceholders(h: *Helper) !usize {
    var arena_state: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dirs: std.StringArrayHashMapUnmanaged(std.ArrayList(cloudfiles.Placeholder)) = .empty;
    try dirs.put(arena, "", .empty);
    const Add = struct {
        fn dir(a: Allocator, d: *@TypeOf(dirs), name: []const u8) !void {
            const entry = try d.getOrPut(a, name);
            if (entry.found_existing) return;
            entry.value_ptr.* = .empty;
            if (name.len == 0) return;
            const parent = std.fs.path.dirnamePosix(name) orelse "";
            try dir(a, d, parent);
            try d.getPtr(parent).?.append(a, .{ .name = try win32.wide(a, std.fs.path.basenamePosix(name)), .dir = true, .size = 0, .identity = 0 });
        }
    };
    for (h.index.files, 0..) |f, i| {
        if (!format.isLayerFile(f.name)) continue;
        switch (f.entry.type) {
            .dir => try Add.dir(arena, &dirs, f.name),
            .reg => {
                const parent = std.fs.path.dirnamePosix(f.name) orelse "";
                try Add.dir(arena, &dirs, parent);
                try dirs.getPtr(parent).?.append(arena, .{ .name = try win32.wide(arena, std.fs.path.basenamePosix(f.name)), .dir = false, .size = f.size, .identity = @intCast(i) });
            },
            // checkDeployable refused anything else.
            else => unreachable,
        }
    }
    const names = dirs.keys();
    const order = try arena.alloc(usize, names.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, names, struct {
        fn less(n: [][]const u8, a: usize, b: usize) bool {
            return depth(n[a]) < depth(n[b]);
        }
    }.less);
    var made: usize = 0;
    for (order) |o| {
        const children = dirs.values()[o].items;
        if (children.len == 0) continue;
        const relative = try arena.dupe(u8, names[o]);
        std.mem.replaceScalar(u8, relative, '/', '\\');
        const base = if (relative.len == 0) h.root else try std.fs.path.join(arena, &.{ h.root, relative });
        made += try cloudfiles.createPlaceholders(arena, base, children);
    }
    return made;
}

// ---------------------------------------------------------------------------
// Serving

fn onFetch(info: *const cloudfiles.CallbackInfo, raw: *const anyopaque) callconv(.winapi) void {
    const h: *Helper = @ptrCast(@alignCast(info.context.?));
    const params: *const cloudfiles.FetchDataParams = @ptrCast(@alignCast(raw));
    _ = h.inflight.fetchAdd(1, .acq_rel);
    defer _ = h.inflight.fetchSub(1, .acq_rel);
    const first: u64 = @intCast(params.required_offset);
    const len: u64 = @intCast(params.required_length);
    var image_buf: [512]u8 = undefined;
    const image = std.fs.path.basenameWindows(cloudfiles.processImage(info, &image_buf));
    const index = cloudfiles.identityOf(info) orelse std.math.maxInt(u32);
    if (index >= h.index.files.len) {
        _ = h.failures.fetchAdd(1, .monotonic);
        note("fetch failed: a file this layer doesn't have, for {s}", .{image});
        _ = cloudfiles.transfer(info, .unsuccessful, null, first, len);
        return;
    }
    const file = &h.index.files[index];
    const failing = if (h.test_fail) |name| std.mem.indexOf(u8, file.name, name) != null else false;
    const served = (if (failing) error.TestFailure else serve(h, info, file, first, first + len)) catch |err| {
        _ = h.failures.fetchAdd(1, .monotonic);
        note("fetch failed: {s}: {s}, for {s}", .{ file.name, describe(err), image });
        const status: cloudfiles.Status = if (err == error.EstargzDigestMismatch) .validation_failed else .unsuccessful;
        _ = cloudfiles.transfer(info, status, null, first, len);
        return;
    };
    note("fetched {s}: {d} bytes, for {s}", .{ file.name, served, image });
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.EstargzDigestMismatch => "its bytes aren't what the layer's TOC says",
        error.Failed => "the registry refused or didn't answer (see above)",
        error.BlobNotFound => "the registry doesn't have the layer any more",
        error.RangeIgnored => "the registry sent the whole blob for a part of it",
        else => @errorName(err),
    };
}

/// Hands Windows each chunk that holds any of the file's bytes from `first`
/// up to `last`, whole, once its digest checks.
fn serve(h: *Helper, info: *const cloudfiles.CallbackInfo, file: *const format.Index.File, first: u64, last: u64) !u64 {
    var scratch: format.Index.Scratch = .{};
    defer scratch.deinit(h.gpa);
    var out: Io.Writer.Allocating = .init(h.gpa);
    defer out.deinit();
    var served: u64 = 0;
    for (file.chunksIn(first, last)) |c| {
        out.clearRetainingCapacity();
        try h.index.readChunk(h.gpa, &scratch, c, &out.writer);
        // A chunk starts at a multiple of 4 MiB, and ends at one or at the
        // file's end, as a transfer must.
        const hr = cloudfiles.transfer(info, .ok, out.written(), c.file_offset, c.size);
        if (hr < 0) {
            note("  Windows refused the transfer: 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.TransferRefused;
        }
        served += c.size;
    }
    return served;
}

fn onCancel(info: *const cloudfiles.CallbackInfo, raw: *const anyopaque) callconv(.winapi) void {
    _ = raw;
    var image_buf: [512]u8 = undefined;
    note("a fetch was cancelled, for {s}", .{std.fs.path.basenameWindows(cloudfiles.processImage(info, &image_buf))});
}

// ---------------------------------------------------------------------------
// The download

fn download(h: *Helper) void {
    var attempts: u32 = 0;
    while (attempts < 3 and !h.stopping.load(.acquire)) : (attempts += 1) {
        downloadOnce(h) catch |err| {
            h.setError("{t}", .{err});
            note("download failed: {t}", .{err});
            return;
        };
        if (h.complete.load(.acquire) or h.stopping.load(.acquire)) return;
    }
    h.setError("the blob didn't match its digest, three times", .{});
}

/// How long to wait before trying again, which doubles up to five minutes.
fn sleepUnlessStopping(h: *Helper, ms: u32) void {
    var left = ms;
    while (left > 0 and !h.stopping.load(.acquire)) {
        const step = @min(left, 250);
        win32.Sleep(step);
        left -= step;
    }
}

fn downloadOnce(h: *Helper) !void {
    const io = h.ctx.io;
    const size = h.desc.size;
    var file = try Io.Dir.cwd().createFile(io, h.part_path, .{ .truncate = false, .read = true });
    var closed = false;
    defer if (!closed) file.close(io);
    var have = try file.length(io);
    if (have > size) {
        try file.setLength(io, 0);
        have = 0;
    }
    const buf = try h.gpa.alloc(u8, 8 << 20);
    defer h.gpa.free(buf);
    // What an earlier helper got, hashed again: the file could be anything.
    var hasher = Sha256.init(.{});
    var pos: u64 = 0;
    while (pos < have) {
        const n = try file.readPositional(io, &.{buf[0..@intCast(@min(buf.len, have - pos))]}, pos);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        pos += n;
    }
    have = pos;
    h.reader.setHave(h.part_path, have);
    h.downloaded.store(have, .release);
    if (have > 0) note("downloading from {d} bytes, which an earlier helper got", .{have});

    var backoff: u32 = 2000;
    while (have < size) {
        if (h.stopping.load(.acquire)) return;
        // Runs come first: fetches are what someone waits for.
        while (h.inflight.load(.acquire) > 0 and !h.stopping.load(.acquire)) win32.Sleep(20);
        // Tests hold the download back while this file is there.
        if (h.test_gate) |gate| while (!h.stopping.load(.acquire) and (Store.exists(io, gate) catch false)) win32.Sleep(100);
        const want: usize = @intCast(@min(size - have, buf.len));
        h.reader.fetch(have, buf[0..want]) catch |err| {
            h.setError("{s}", .{describe(err)});
            note("download paused at {d} of {d} bytes: {s}; trying again in {d} s", .{ have, size, describe(err), backoff / 1000 });
            sleepUnlessStopping(h, backoff);
            backoff = @min(backoff * 2, 300_000);
            continue;
        };
        try file.writePositionalAll(io, buf[0..want], have);
        hasher.update(buf[0..want]);
        have += want;
        h.reader.setDownloaded(have);
        h.downloaded.store(have, .release);
        h.progress_at.store(nowSeconds(), .monotonic);
        if (backoff != 2000) h.setError("", .{});
        backoff = 2000;
    }
    file.close(io);
    closed = true;

    const hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    if (!std.mem.eql(u8, &hex, h.hex)) {
        note("the downloaded blob doesn't match its digest: starting again", .{});
        h.reader.setHave("", 0);
        h.downloaded.store(0, .release);
        try Io.Dir.cwd().deleteFile(io, h.part_path);
        return;
    }
    // Into the store, as any blob, while no prune runs.
    var arena_state: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const store_lock = try h.ctx.store.lock(arena, .shared);
    defer store_lock.release(io);
    _ = try h.ctx.store.putBlobFile(arena, h.part_path, .{ .hex = hex, .size = size }, h.desc.mediaType);
    h.reader.setHave(h.blob_path, size);
    h.complete.store(true, .release);
    note("downloaded and checked the whole blob", .{});
}

// ---------------------------------------------------------------------------
// The swap

/// Unpacks the blob, if it isn't yet, and swaps it in for the placeholders
/// once no run holds the deployment. False if it has to wait.
fn swap(h: *Helper, arena: Allocator) !bool {
    const ctx = h.ctx;
    const io = ctx.io;
    const store = ctx.store;
    if (h.unpacked == null) {
        // In tmp\, with its lock held, so that prune leaves it.
        const work = try store.makeTmpDir(h.gpa, "lazy");
        h.unpacked_lock = try Store.openLock(io, try Store.lockPathFor(h.gpa, work), .exclusive, .wait);
        const tree = try std.fs.path.join(h.gpa, &.{ work, "app" });
        lazy.writeState(store, arena, h.hex, .{ .phase = "unpacking", .downloaded = h.desc.size, .size = h.desc.size, .pid = win32.GetCurrentProcessId() }) catch {};
        format.deploy(io, h.gpa, h.gpa, false, h.desc, h.blob_path, work, tree) catch |err| {
            note("unpacking the layer failed: {t}; trying again later", .{err});
            Store.deleteTree(io, arena, work) catch {};
            return false;
        };
        h.unpacked = tree;
        note("unpacked; waiting for no run to use the deployment", .{});
    }
    const in_use = try Store.tryLock(io, try Store.lockPathFor(arena, h.root), .exclusive) orelse return false;
    defer in_use.release(io);
    const store_lock = try store.lock(arena, .shared);
    defer store_lock.release(io);
    lazy.writeState(store, arena, h.hex, .{ .phase = "swapping", .downloaded = h.desc.size, .size = h.desc.size, .pid = win32.GetCurrentProcessId() }) catch {};

    if (h.conn) |c| c.disconnect();
    h.conn = null;
    try acl.unprotect(arena, h.root);
    const trash = try store.tmpPath(arena, "trash");
    Io.Dir.rename(.cwd(), h.root, .cwd(), trash, io) catch |err| {
        // A file in it is open, outside any run: Explorer's, say.
        note("the placeholders can't be moved yet ({t}); trying again later", .{err});
        acl.protect(arena, h.root) catch {};
        h.conn = try cloudfiles.connect(h.gpa, h.root, h, onFetch, onCancel);
        return false;
    };
    Io.Dir.rename(.cwd(), h.unpacked.?, .cwd(), h.root, io) catch |err| {
        // Someone deployed it meanwhile, from the blob: that's as good.
        if (!try Store.exists(io, h.root)) return err;
    };
    try acl.protect(arena, h.root);
    // The layer's folder in lazy\ goes before the deployment is free, so
    // that a run finds nothing left to serve; its helper lock is beside it.
    Store.deleteTree(io, arena, try lazy.dirPath(store, arena, h.hex)) catch |err|
        note("warning: couldn't delete the layer's folder in lazy\\ ({t}); `zigsaw prune` will retry", .{err});
    const work = std.fs.path.dirname(h.unpacked.?).?;
    Store.deleteTree(io, arena, work) catch {};
    if (h.unpacked_lock) |l| l.release(io);
    Io.Dir.cwd().deleteFile(io, try Store.lockPathFor(arena, work)) catch {};
    cloudfiles.unregister(arena, trash) catch {};
    Store.deleteTree(io, arena, trash) catch |err|
        note("warning: couldn't delete the placeholders in {s} ({t}); `zigsaw prune` will retry", .{ trash, err });
    return true;
}
