//! DER, read with care: what's read here (certificates, timestamps) comes from
//! anyone, and std's parser takes a length as it comes. Every element is checked to
//! end where its parent does, or before.

const std = @import("std");
const Certificate = std.crypto.Certificate;
pub const Element = Certificate.der.Element;
pub const Tag = Certificate.der.Tag;

pub const Error = error{Malformed};

/// The element at `i`, which must end by `end`.
pub fn element(bytes: []const u8, i: usize, end: usize) Error!Element {
    if (end > bytes.len or i + 2 > end) return error.Malformed;
    // A long form's length bytes, which std's parser reads without looking.
    if (bytes[i + 1] & 0x80 != 0 and i + 2 + (bytes[i + 1] & 0x7f) > end) return error.Malformed;
    const e = Element.parse(bytes[0..end], @intCast(i)) catch return error.Malformed;
    if (e.slice.start > end or e.slice.end > end or e.slice.end < e.slice.start) return error.Malformed;
    return e;
}

/// The elements inside a constructed one, in order.
pub const Children = struct {
    bytes: []const u8,
    at: usize,
    end: usize,

    pub fn of(bytes: []const u8, parent: Element) Children {
        return .{ .bytes = bytes, .at = parent.slice.start, .end = parent.slice.end };
    }

    /// The next one, or null when there are no more.
    pub fn next(c: *Children) Error!?Element {
        if (c.at >= c.end) return null;
        const e = try element(c.bytes, c.at, c.end);
        c.at = e.slice.end;
        return e;
    }

    /// The next one, which must be there.
    pub fn need(c: *Children) Error!Element {
        return try c.next() orelse error.Malformed;
    }
};

/// What's inside an element.
pub fn content(bytes: []const u8, e: Element) []const u8 {
    return bytes[e.slice.start..e.slice.end];
}

/// An element whole: its tag and length too, as a signature over it covers them.
pub fn whole(bytes: []const u8, start: usize, e: Element) []const u8 {
    return bytes[start..e.slice.end];
}

pub fn isTag(e: Element, tag: Tag) bool {
    return e.identifier.class == .universal and e.identifier.tag == tag;
}

/// Whether `e` is the context-specific [n].
pub fn isContext(e: Element, n: u5) bool {
    return e.identifier.class == .context_specific and @backingInt(e.identifier.tag) == n;
}

/// Seconds since 1970 of a civil date and time in UTC (Howard Hinnant's
/// days_from_civil), or null if it isn't one.
pub fn epochSeconds(y: i64, m: i64, d: i64, hh: i64, mm: i64, ss: i64) ?i64 {
    if (m < 1 or m > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60 or hh < 0 or mm < 0 or ss < 0) return null;
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/// Seconds since 1970 of a GeneralizedTime as DER has it: YYYYMMDDHHMMSS, perhaps
/// fractions of a second (dropped), then Z.
pub fn generalizedTime(text: []const u8) ?i64 {
    if (text.len < 15 or text[text.len - 1] != 'Z') return null;
    if (text.len > 15 and (text[14] != '.' or text.len < 17)) return null;
    for (text[0..14]) |c| if (!std.ascii.isDigit(c)) return null;
    if (text.len > 15) for (text[15 .. text.len - 1]) |c| if (!std.ascii.isDigit(c)) return null;
    const n = struct {
        fn of(s: []const u8) i64 {
            return std.fmt.parseInt(i64, s, 10) catch unreachable; // Digits, checked.
        }
    }.of;
    return epochSeconds(n(text[0..4]), n(text[4..6]), n(text[6..8]), n(text[8..10]), n(text[10..12]), n(text[12..14]));
}

const testing = std.testing;

test "lengths that run past their parent are an error, not a crash" {
    try testing.expectError(error.Malformed, element(&.{ 0x30, 0x84, 0x01 }, 0, 3));
    try testing.expectError(error.Malformed, element(&.{ 0x30, 0x05, 0x30, 0x00 }, 0, 4));
    try testing.expectError(error.Malformed, element(&.{0x30}, 0, 1));
    // Inside a parent that ends first.
    const bytes = [_]u8{ 0x30, 0x02, 0x04, 0x05, 0x00, 0x00, 0x00 };
    var c: Children = .of(&bytes, try element(&bytes, 0, bytes.len));
    try testing.expectError(error.Malformed, c.next());
}

test "GeneralizedTime as a timestamp authority writes it" {
    try testing.expectEqual(@as(?i64, 1794163745), generalizedTime("20261108184905Z"));
    try testing.expectEqual(@as(?i64, 1794163745), generalizedTime("20261108184905.123Z"));
    try testing.expectEqual(@as(?i64, 0), generalizedTime("19700101000000Z"));
    try testing.expectEqual(@as(?i64, null), generalizedTime("20261108184905"));
    try testing.expectEqual(@as(?i64, null), generalizedTime("20261108184905.Z"));
    try testing.expectEqual(@as(?i64, null), generalizedTime("2026110818490Z"));
    try testing.expectEqual(@as(?i64, null), generalizedTime("20261308184905Z"));
    try testing.expectEqual(@as(?i64, null), generalizedTime("2026110818490aZ"));
}
