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

/// Reads a net message stream at bit level, like ReHLTV `common/BitBuffer.cpp`:
/// bits LSB first within each byte, multi-bit values little-endian.
///
/// In ReHLTV every read (bytes, shorts, strings) is a bit read from the
/// current bit position; bit-mode messages realign to a byte when they end
/// (`alignByte`). Reads that only make sense on a byte boundary (`bytes`,
/// `string`) return `error.Misaligned` elsewhere.
pub const BitReader = struct {
    buf: []const u8,
    /// Position in bits from the start of `buf`.
    bit: usize = 0,

    pub const Error = error{ EndOfBuffer, Misaligned };

    /// Longest string `string` returns, like ReHLTV's 8192-byte buffer
    /// (8191 chars plus NUL).
    pub const max_string = 8191;

    pub fn init(buf: []const u8) BitReader {
        return .{ .buf = buf };
    }

    pub fn bitsLeft(r: BitReader) usize {
        return r.buf.len * 8 - r.bit;
    }

    /// Byte offset of the current position (rounded down).
    pub fn byteOffset(r: BitReader) usize {
        return r.bit / 8;
    }

    pub fn isAligned(r: BitReader) bool {
        return r.bit % 8 == 0;
    }

    pub fn atEnd(r: BitReader) bool {
        return r.bit == r.buf.len * 8;
    }

    /// Moves to the next byte boundary, if not on one (ReHLTV `AlignByte`,
    /// done by `EndBitMode`).
    pub fn alignByte(r: *BitReader) void {
        r.bit = std.mem.alignForward(usize, r.bit, 8);
    }

    /// `n` (0..32) bits as an unsigned value.
    pub fn readBits(r: *BitReader, n: u6) Error!u32 {
        const v = try r.peekBits(n);
        r.bit += n;
        return v;
    }

    /// `n` (0..32) bits without consuming them.
    pub fn peekBits(r: BitReader, n: u6) Error!u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        if (n > r.bitsLeft()) return error.EndOfBuffer;
        const first = r.bit / 8;
        const shift: u6 = @intCast(r.bit % 8);
        // At most 7 + 32 = 39 bits: 5 bytes.
        const avail = @min(5, r.buf.len - first);
        var window: u64 = 0;
        for (r.buf[first..][0..avail], 0..) |b, i| window |= @as(u64, b) << @intCast(i * 8);
        const mask = (@as(u64, 1) << n) - 1;
        return @intCast((window >> shift) & mask);
    }

    pub fn readBit(r: *BitReader) Error!bool {
        return try r.readBits(1) == 1;
    }

    /// Sign and magnitude: one sign bit, then `n - 1` bits (ReHLTV
    /// `ReadSBits`). `n` is 1..32.
    pub fn readSBits(r: *BitReader, n: u6) Error!i32 {
        std.debug.assert(n >= 1 and n <= 32);
        if (n > r.bitsLeft()) return error.EndOfBuffer;
        const negative = try r.readBit();
        const magnitude: i64 = try r.readBits(n - 1);
        return @intCast(if (negative) -magnitude else magnitude);
    }

    pub fn skipBits(r: *BitReader, n: usize) Error!void {
        if (n > r.bitsLeft()) return error.EndOfBuffer;
        r.bit += n;
    }

    pub fn readByte(r: *BitReader) Error!u8 {
        return @intCast(try r.readBits(8));
    }

    /// A signed byte (ReHLTV `ReadChar` as used for angles).
    pub fn readChar(r: *BitReader) Error!i8 {
        return @bitCast(try r.readByte());
    }

    pub fn readShort(r: *BitReader) Error!u16 {
        return @intCast(try r.readBits(16));
    }

    pub fn readLong(r: *BitReader) Error!u32 {
        return r.readBits(32);
    }

    pub fn readFloat(r: *BitReader) Error!f32 {
        return @bitCast(try r.readLong());
    }

    pub fn skipBytes(r: *BitReader, n: usize) Error!void {
        if (n > r.bitsLeft() / 8) return error.EndOfBuffer;
        r.bit += n * 8;
    }

    /// The next `n` bytes, borrowed. Only on a byte boundary.
    pub fn bytes(r: *BitReader, n: usize) Error![]const u8 {
        if (!r.isAligned()) return error.Misaligned;
        const start = r.bit / 8;
        if (n > r.buf.len - start) return error.EndOfBuffer;
        r.bit += n * 8;
        return r.buf[start..][0..n];
    }

    /// A NUL-terminated string, borrowed, without the NUL. Only on a byte
    /// boundary. Like ReHLTV `ReadString`, stops after `max_string` chars
    /// even without a NUL (the rest is read as what follows). Running out of
    /// data before a NUL is `error.EndOfBuffer`.
    pub fn string(r: *BitReader) Error![]const u8 {
        if (!r.isAligned()) return error.Misaligned;
        const start = r.bit / 8;
        const rest = r.buf[start..];
        const limit = @min(rest.len, max_string);
        if (std.mem.indexOfScalar(u8, rest[0..limit], 0)) |len| {
            r.bit += (len + 1) * 8;
            return rest[0..len];
        }
        if (limit == max_string) {
            r.bit += max_string * 8;
            return rest[0..max_string];
        }
        return error.EndOfBuffer;
    }

    /// Skips a string of 8-bit chars up to and including a NUL, at any bit
    /// position (ReHLTV `ReadBitString`, delta `DT_STRING`). No length limit.
    pub fn skipBitString(r: *BitReader) Error!void {
        while (try r.readByte() != 0) {}
    }

    /// ReHLTV `ReadBitCoord`: int and fraction flags, sign, 12-bit integer,
    /// 3-bit fraction (eighths).
    pub fn readBitCoord(r: *BitReader) Error!f32 {
        const has_int = try r.readBit();
        const has_frac = try r.readBit();
        if (!has_int and !has_frac) return 0;
        const negative = try r.readBit();
        const int_part: f32 = if (has_int) @floatFromInt(try r.readBits(12)) else 0;
        const frac_part: f32 = if (has_frac) @floatFromInt(try r.readBits(3)) else 0;
        const v = int_part + frac_part / 8;
        return if (negative) -v else v;
    }

    /// ReHLTV `ReadBitVec3Coord`: three presence flags, then each present
    /// coordinate. Absent ones are 0.
    pub fn readBitVec3Coord(r: *BitReader) Error![3]f32 {
        var present: [3]bool = undefined;
        for (&present) |*p| p.* = try r.readBit();
        var v: [3]f32 = @splat(0);
        for (present, &v) |p, *c| {
            if (p) c.* = try r.readBitCoord();
        }
        return v;
    }
};

/// Writes bit streams in the same layout `BitReader` reads. For building
/// test inputs.
pub const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit: usize = 0,

    pub fn deinit(w: *BitWriter, gpa: std.mem.Allocator) void {
        w.bytes.deinit(gpa);
    }

    /// The low `n` (0..32) bits of `v`.
    pub fn bits(w: *BitWriter, gpa: std.mem.Allocator, v: u32, n: u6) !void {
        for (0..n) |i| {
            if (w.bit % 8 == 0) try w.bytes.append(gpa, 0);
            const set: u8 = @intCast((v >> @intCast(i)) & 1);
            w.bytes.items[w.bit / 8] |= set << @intCast(w.bit % 8);
            w.bit += 1;
        }
    }

    pub fn bit1(w: *BitWriter, gpa: std.mem.Allocator, v: bool) !void {
        try w.bits(gpa, @intFromBool(v), 1);
    }

    /// Sign and magnitude in `n` bits.
    pub fn sbits(w: *BitWriter, gpa: std.mem.Allocator, v: i32, n: u6) !void {
        try w.bit1(gpa, v < 0);
        try w.bits(gpa, @intCast(@abs(v)), n - 1);
    }

    pub fn byte(w: *BitWriter, gpa: std.mem.Allocator, v: u8) !void {
        try w.bits(gpa, v, 8);
    }

    pub fn short(w: *BitWriter, gpa: std.mem.Allocator, v: u16) !void {
        try w.bits(gpa, v, 16);
    }

    pub fn long(w: *BitWriter, gpa: std.mem.Allocator, v: u32) !void {
        try w.bits(gpa, v, 32);
    }

    /// 8-bit chars and a NUL, at any bit position.
    pub fn string(w: *BitWriter, gpa: std.mem.Allocator, s: []const u8) !void {
        for (s) |c| try w.byte(gpa, c);
        try w.byte(gpa, 0);
    }

    /// Pads to a byte boundary with zero bits.
    pub fn alignByte(w: *BitWriter) void {
        w.bit = std.mem.alignForward(usize, w.bit, 8);
    }

    pub fn slice(w: BitWriter) []const u8 {
        return w.bytes.items;
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

test "BitReader: bits are LSB first and cross byte boundaries" {
    // 0b1011_0110, 0b1100_0011
    var r: BitReader = .init(&.{ 0xb6, 0xc3 });
    try testing.expectEqual(@as(u32, 0b0110), try r.readBits(4));
    try testing.expectEqual(true, try r.readBit());
    try testing.expectEqual(@as(u32, 0b101), try r.readBits(3));
    try testing.expect(r.isAligned());
    var r2: BitReader = .init(&.{ 0xb6, 0xc3 });
    try r2.skipBits(5);
    // Bits 5..12: 101 from byte 0, then 00011 from byte 1.
    try testing.expectEqual(@as(u32, 0b00011_101), try r2.readBits(8));
    try testing.expectEqual(@as(usize, 3), r2.bitsLeft());
}

test "BitReader: 32-bit reads at every bit offset" {
    const data = [_]u8{ 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x89 };
    const whole = std.mem.readInt(u64, &data, .little);
    for (0..33) |off| {
        var r: BitReader = .init(&data);
        try r.skipBits(off);
        const want: u32 = @truncate(whole >> @intCast(off));
        try testing.expectEqual(want, try r.readBits(32));
    }
}

test "BitReader: little-endian shorts, longs and floats" {
    var r: BitReader = .init(&.{ 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x00, 0x00, 0x80, 0x3f, 0xff });
    try testing.expectEqual(@as(u16, 0x1234), try r.readShort());
    try testing.expectEqual(@as(u32, 0x12345678), try r.readLong());
    try testing.expectEqual(@as(f32, 1.0), try r.readFloat());
    try testing.expectEqual(@as(i8, -1), try r.readChar());
}

test "BitReader: signed values are sign and magnitude" {
    // Sign bit 1, magnitude 5 in 7 bits: 0b0000101_1 = 0x0b.
    var r: BitReader = .init(&.{ 0x0b, 0x0a });
    try testing.expectEqual(@as(i32, -5), try r.readSBits(8));
    // Sign 0, magnitude 5.
    try testing.expectEqual(@as(i32, 5), try r.readSBits(8));
    var r1: BitReader = .init(&.{0x01});
    try testing.expectEqual(@as(i32, 0), try r1.readSBits(1)); // "negative zero"
}

test "BitReader: reading past the end errors and keeps the position" {
    var r: BitReader = .init(&.{ 0xff, 0x01 });
    try r.skipBits(3);
    try testing.expectError(error.EndOfBuffer, r.readBits(14));
    try testing.expectEqual(@as(usize, 3), r.bit);
    try testing.expectEqual(@as(u32, 0x3f), try r.readBits(13) & 0x3f);
    try testing.expectError(error.EndOfBuffer, r.readBit());
    try testing.expectError(error.EndOfBuffer, r.skipBits(1));
    try testing.expectEqual(@as(u32, 0), try r.readBits(0));
    var e: BitReader = .init(&.{});
    try testing.expectError(error.EndOfBuffer, e.readSBits(1));
    try testing.expectError(error.EndOfBuffer, e.peekBits(1));
}

test "BitReader: peek does not consume" {
    var r: BitReader = .init(&.{ 0xff, 0xff, 0x00 });
    try testing.expectEqual(@as(u32, 0xffff), try r.peekBits(16));
    try testing.expectEqual(@as(usize, 0), r.bit);
}

test "BitReader: strings and bytes need a byte boundary" {
    var r: BitReader = .init("ab\x00cd\x00\x07xyz");
    try testing.expectEqualStrings("ab", try r.string());
    try testing.expectEqualStrings("cd", try r.string());
    _ = try r.readBit();
    try testing.expectError(error.Misaligned, r.string());
    try testing.expectError(error.Misaligned, r.bytes(1));
    r.alignByte();
    try testing.expectEqualSlices(u8, "xy", try r.bytes(2));
    // No NUL before the end.
    try testing.expectError(error.EndOfBuffer, r.string());
    try testing.expectError(error.EndOfBuffer, r.bytes(2));
    r.alignByte(); // already aligned: no move
    try testing.expectEqualSlices(u8, "z", try r.bytes(1));
    try testing.expect(r.atEnd());
}

test "BitReader: strings stop at 8191 chars like ReHLTV" {
    var buf: [BitReader.max_string + 2]u8 = @splat('a');
    buf[buf.len - 1] = 0;
    var r: BitReader = .init(&buf);
    try testing.expectEqual(@as(usize, BitReader.max_string), (try r.string()).len);
    // The 8192nd char and the NUL are left over.
    try testing.expectEqualStrings("a", try r.string());
}

test "BitReader: bit strings at any offset" {
    // "hi\0" shifted by one bit, then a 1 bit.
    const raw = [_]u8{ 'h', 'i', 0 };
    const v = std.mem.readInt(u24, &raw, .little);
    const shifted: u32 = (@as(u32, v) << 1) | 1 | (1 << 25);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, shifted, .little);
    var r: BitReader = .init(&b);
    try testing.expect(try r.readBit());
    try r.skipBitString();
    try testing.expectEqual(@as(usize, 25), r.bit);
    try testing.expect(try r.readBit());
}

test "BitReader: bit coords" {
    // flags int=1 frac=1, sign=1, int=3 (12 bits), frac=4 (3 bits): -3.5
    var bits: u32 = 0;
    var n: u5 = 0;
    for ([_]struct { v: u32, w: u5 }{ .{ .v = 1, .w = 1 }, .{ .v = 1, .w = 1 }, .{ .v = 1, .w = 1 }, .{ .v = 3, .w = 12 }, .{ .v = 4, .w = 3 } }) |f| {
        bits |= f.v << n;
        n += f.w;
    }
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, bits, .little);
    var r: BitReader = .init(&b);
    try testing.expectEqual(@as(f32, -3.5), try r.readBitCoord());
    try testing.expectEqual(@as(usize, 18), r.bit);
    var z: BitReader = .init(&.{0});
    try testing.expectEqual(@as(f32, 0), try z.readBitCoord());
    try testing.expectEqual(@as(usize, 2), z.bit);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, try z.readBitVec3Coord());
}

test "BitWriter round-trips through BitReader" {
    const gpa = testing.allocator;
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.bits(gpa, 5, 3);
    try w.sbits(gpa, -100, 12);
    try w.long(gpa, 0xdeadbeef);
    try w.string(gpa, "x");
    w.alignByte();
    try w.byte(gpa, 0xab);
    var r: BitReader = .init(w.slice());
    try testing.expectEqual(@as(u32, 5), try r.readBits(3));
    try testing.expectEqual(@as(i32, -100), try r.readSBits(12));
    try testing.expectEqual(@as(u32, 0xdeadbeef), try r.readLong());
    try r.skipBitString();
    r.alignByte();
    try testing.expectEqual(@as(u8, 0xab), try r.readByte());
    try testing.expect(r.atEnd());
}
