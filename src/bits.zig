//! Bounds-checked little-endian readers. Knows nothing about demos.
//!
//! Every read checks the length against what is left and returns
//! `error.EndOfBuffer` instead of reading past the end. A failed read leaves
//! the position unchanged.

const std = @import("std");

/// Reads bytes, little-endian integers and floats, and strings from a slice.
pub const ByteReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub const Error = error{EndOfBuffer};

    pub fn init(buf: []const u8) ByteReader {
        return .{ .buf = buf };
    }

    /// Bytes left to read.
    pub fn remaining(r: ByteReader) usize {
        return r.buf.len - r.pos;
    }

    /// True when everything has been read.
    pub fn atEnd(r: ByteReader) bool {
        return r.pos == r.buf.len;
    }

    /// The next `n` bytes, borrowed from the buffer.
    pub fn bytes(r: *ByteReader, n: usize) Error![]const u8 {
        if (n > r.remaining()) return error.EndOfBuffer;
        const out = r.buf[r.pos..][0..n];
        r.pos += n;
        return out;
    }

    /// The next `n` bytes as a fixed-size array pointer.
    pub fn array(r: *ByteReader, comptime n: usize) Error!*const [n]u8 {
        return (try r.bytes(n))[0..n];
    }

    pub fn skip(r: *ByteReader, n: usize) Error!void {
        _ = try r.bytes(n);
    }

    /// A little-endian integer of type `T` (u8, i32, u16, ...).
    pub fn int(r: *ByteReader, comptime T: type) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        return std.mem.readInt(T, try r.array(n), .little);
    }

    /// A little-endian IEEE 754 f32.
    pub fn float(r: *ByteReader) Error!f32 {
        return @bitCast(try r.int(u32));
    }

    /// A fixed-size field of `n` bytes holding a NUL-padded string. Returns the
    /// part before the first NUL (all `n` bytes if there is none).
    pub fn fixedString(r: *ByteReader, n: usize) Error![]const u8 {
        const field = try r.bytes(n);
        return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse n];
    }

    /// A NUL-terminated string. Consumes the NUL, returns the bytes before it.
    /// `error.EndOfBuffer` if there is no NUL before the end.
    pub fn cString(r: *ByteReader) Error![]const u8 {
        const rest = r.buf[r.pos..];
        const len = std.mem.indexOfScalar(u8, rest, 0) orelse return error.EndOfBuffer;
        r.pos += len + 1;
        return rest[0..len];
    }
};

const testing = std.testing;

test "ByteReader: integers are little-endian" {
    var r: ByteReader = .init(&.{ 0x01, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xff, 0xff, 0xff, 0xff });
    try testing.expectEqual(@as(u8, 1), try r.int(u8));
    try testing.expectEqual(@as(u16, 0x1234), try r.int(u16));
    try testing.expectEqual(@as(u32, 0x12345678), try r.int(u32));
    try testing.expectEqual(@as(i32, -1), try r.int(i32));
    try testing.expect(r.atEnd());
}

test "ByteReader: u64 and f32" {
    var r: ByteReader = .init(&.{ 0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x10, 0x01, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0xbf });
    try testing.expectEqual(@as(u64, 0x01100001_12345678), try r.int(u64));
    try testing.expectEqual(@as(f32, 1.0), try r.float());
    try testing.expectEqual(@as(f32, -1.0), try r.float());
}

test "ByteReader: reading past the end errors and keeps the position" {
    var r: ByteReader = .init(&.{ 1, 2, 3 });
    try testing.expectError(error.EndOfBuffer, r.int(u32));
    try testing.expectEqual(@as(usize, 0), r.pos);
    try testing.expectEqual(@as(u16, 0x0201), try r.int(u16));
    try testing.expectError(error.EndOfBuffer, r.bytes(2));
    try testing.expectError(error.EndOfBuffer, r.skip(2));
    try testing.expectEqual(@as(usize, 1), r.remaining());
    try testing.expectEqualSlices(u8, &.{3}, try r.bytes(1));
    try testing.expectError(error.EndOfBuffer, r.int(u8));
    try testing.expectEqualSlices(u8, &.{}, try r.bytes(0));
}

test "ByteReader: fixed-size strings" {
    var r: ByteReader = .init("de_dust2\x00\x00\x00\x00abcd");
    try testing.expectEqualStrings("de_dust2", try r.fixedString(12));
    // No NUL inside the field: the whole field.
    try testing.expectEqualStrings("abcd", try r.fixedString(4));
    try testing.expectError(error.EndOfBuffer, r.fixedString(1));
}

test "ByteReader: NUL-terminated strings" {
    var r: ByteReader = .init("name\x00\x00rest");
    try testing.expectEqualStrings("name", try r.cString());
    try testing.expectEqualStrings("", try r.cString());
    try testing.expectError(error.EndOfBuffer, r.cString());
    try testing.expectEqual(@as(usize, 6), r.pos);
}
