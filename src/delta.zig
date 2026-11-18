//! Delta compression (ReHLTV `Core/src/Delta.cpp`, doc/FORMAT.md).
//!
//! The server describes each delta-encoded struct with `svc_deltadescription`
//! (a table of fields, itself delta-encoded against the built-in meta table).
//! A delta-encoded value is a field mask followed by the sent fields. We only
//! need to skip values correctly: how many bits a value takes depends on the
//! table and the mask, never on the previous value.

const std = @import("std");
const bits = @import("bits.zig");
const BitReader = bits.BitReader;

/// Field types (`DT_*` in ReHLDS `engine/delta.h`).
pub const FieldType = enum(u32) {
    byte = 1 << 0,
    short = 1 << 1,
    float = 1 << 2,
    integer = 1 << 3,
    angle = 1 << 4,
    /// Time relative to the frame, 8 signed bits in hundredths.
    timewindow_8 = 1 << 5,
    /// Time relative to the frame, `bits` signed bits.
    timewindow_big = 1 << 6,
    /// NUL-terminated 8-bit chars.
    string = 1 << 7,
    _,
};

/// Added to the field type for sign-and-magnitude values (`DT_SIGNED`).
pub const signed_flag: u32 = 1 << 31;

/// Longest field name kept (`delta_description_t.fieldName` is 32 bytes).
pub const max_name = 32;

/// Fields a mask can cover: up to 7 mask bytes (3-bit count).
pub const max_sent_fields = 7 * 8;

/// One field of a delta description.
pub const Field = struct {
    /// Type and `signed_flag`.
    flags: u32,
    /// Significant bits of the value on the wire.
    bits: u8,
    /// Divisor applied to the wire value (only kept for diagnostics).
    premultiply: f32 = 1,
    name_buf: [max_name]u8 = @splat(0),
    name_len: u8 = 0,

    pub fn init(flags: u32, field_bits: u8, field_name: []const u8) Field {
        var f: Field = .{ .flags = flags, .bits = field_bits };
        f.setName(field_name);
        return f;
    }

    pub fn kind(f: Field) FieldType {
        return @fromBackingInt(@intCast(f.flags & ~signed_flag));
    }

    pub fn isSigned(f: Field) bool {
        return f.flags & signed_flag != 0;
    }

    pub fn name(f: *const Field) []const u8 {
        return f.name_buf[0..f.name_len];
    }

    fn setName(f: *Field, s: []const u8) void {
        const n = @min(s.len, max_name);
        @memcpy(f.name_buf[0..n], s[0..n]);
        f.name_len = @intCast(n);
    }
};

pub const Error = BitReader.Error || error{
    /// A sent field has a type we can't read, so its size is unknown.
    UnknownFieldType,
    /// A sent field has a bit count the reader can't use (over 32, or 0 for
    /// a signed value).
    BadFieldBits,
};

/// The built-in description of `delta_description_t`, used to decode the
/// tables in `svc_deltadescription` (ReHLTV `Delta::m_MetaDescription`).
pub const meta_fields = [_]Field{
    .init(@backingInt(FieldType.integer), 32, "fieldType"),
    .init(@backingInt(FieldType.string), 1, "fieldName"),
    .init(@backingInt(FieldType.integer), 16, "fieldOffset"),
    .init(@backingInt(FieldType.integer), 8, "fieldSize"),
    .init(@backingInt(FieldType.integer), 8, "significant_bits"),
    .init(@backingInt(FieldType.float), 32, "premultiply"),
    .init(@backingInt(FieldType.float), 32, "postmultiply"),
};

/// Which fields were sent: `mask[i / 32] >> (i % 32)`.
const Mask = [2]u32;

fn readMask(r: *BitReader) Error!Mask {
    var raw: [8]u8 = @splat(0);
    const n = try r.readBits(3);
    for (raw[0..n]) |*b| b.* = try r.readByte();
    return .{ std.mem.readInt(u32, raw[0..4], .little), std.mem.readInt(u32, raw[4..8], .little) };
}

fn isSent(mask: Mask, i: usize) bool {
    if (i >= 64) return false;
    return (mask[i / 32] >> @intCast(i % 32)) & 1 != 0;
}

fn checkedBits(f: Field, signed: bool) Error!u6 {
    if (f.bits > 32) return error.BadFieldBits;
    if (signed and f.bits == 0) return error.BadFieldBits;
    return @intCast(f.bits);
}

/// Reads one sent field (ReHLTV `Delta::ParseDelta`, per type). Returns the
/// raw wire value of numeric fields (sign applied), 0 for strings. A string
/// is copied (truncated to `max_name`) into `string_out` if given.
fn readField(r: *BitReader, f: Field, string_out: ?*Field) Error!i64 {
    switch (f.kind()) {
        .byte, .short, .float, .integer => {
            const n = try checkedBits(f, f.isSigned());
            return if (f.isSigned()) try r.readSBits(n) else try r.readBits(n);
        },
        .angle => return try r.readBits(try checkedBits(f, false)),
        .timewindow_8 => return try r.readSBits(8),
        .timewindow_big => return try r.readSBits(try checkedBits(f, true)),
        .string => {
            var buf: [max_name]u8 = undefined;
            var len: usize = 0;
            while (true) {
                const c = try r.readByte();
                if (c == 0) break;
                if (len < max_name) {
                    buf[len] = c;
                    len += 1;
                }
            }
            if (string_out) |out| out.setName(buf[0..len]);
            return 0;
        },
        _ => return error.UnknownFieldType,
    }
}

/// Skips one delta-encoded value described by `fields`.
pub fn skip(r: *BitReader, fields: []const Field) Error!void {
    const mask = try readMask(r);
    for (fields, 0..) |f, i| {
        if (isSent(mask, i)) _ = try readField(r, f, null);
    }
}

/// Reads one field description, delta-encoded against zeroes with
/// `meta_fields`.
pub fn readFieldDescription(r: *BitReader) Error!Field {
    const mask = try readMask(r);
    var out: Field = .{ .flags = 0, .bits = 0, .premultiply = 0 };
    for (meta_fields, 0..) |mf, i| {
        if (!isSent(mask, i)) continue;
        const v = try readField(r, mf, &out);
        switch (i) {
            0 => out.flags = @intCast(v),
            4 => out.bits = @intCast(v),
            // The float fields are sent multiplied by 4000.
            5 => out.premultiply = @floatCast(@as(f64, @floatFromInt(v)) / 4000.0),
            else => {},
        }
    }
    return out;
}

/// The delta descriptions received so far, by name (case-insensitive, like
/// ReHLTV `LookupRegistration`). A new description replaces an old one.
pub const Tables = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        name: []u8,
        fields: []Field,
    };

    pub fn deinit(t: *Tables, gpa: std.mem.Allocator) void {
        for (t.entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.fields);
        }
        t.entries.deinit(gpa);
    }

    /// The fields of table `name`, or null if it hasn't been received.
    pub fn get(t: *const Tables, name: []const u8) ?[]const Field {
        for (t.entries.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) return e.fields;
        }
        return null;
    }

    /// Stores `fields` (taking ownership) under a copy of `name`.
    pub fn put(t: *Tables, gpa: std.mem.Allocator, name: []const u8, fields: []Field) !void {
        for (t.entries.items) |*e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) {
                gpa.free(e.fields);
                e.fields = fields;
                return;
            }
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try t.entries.append(gpa, .{ .name = owned, .fields = fields });
    }
};

/// Reads the body of an `svc_deltadescription` (after the id) into `tables`
/// (ReHLTV `World::ParseDeltaDescription`): table name (byte string), then in
/// bit mode a 16-bit field count and each field description. Ends aligned to
/// a byte.
pub fn readDescription(gpa: std.mem.Allocator, r: *BitReader, tables: *Tables) (Error || error{ EmptyTableName, OutOfMemory })!void {
    const name = try r.string();
    if (name.len == 0) return error.EmptyTableName;
    const count = try r.readShort();
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(gpa);
    for (0..count) |_| try fields.append(gpa, try readFieldDescription(r));
    r.alignByte();
    const owned = try fields.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    try tables.put(gpa, name, owned);
}

const testing = std.testing;
const BitWriter = bits.BitWriter;

/// Writes a mask with the given field indexes set.
fn writeMask(w: *BitWriter, gpa: std.mem.Allocator, sent: []const u6) !void {
    var raw: [8]u8 = @splat(0);
    var nbytes: u32 = 0;
    for (sent) |i| {
        raw[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        nbytes = @max(nbytes, i / 8 + 1);
    }
    try w.bits(gpa, nbytes, 3);
    for (raw[0..nbytes]) |b| try w.byte(gpa, b);
}

const t_byte = @backingInt(FieldType.byte);
const t_short = @backingInt(FieldType.short);
const t_float = @backingInt(FieldType.float);
const t_int = @backingInt(FieldType.integer);
const t_angle = @backingInt(FieldType.angle);
const t_tw8 = @backingInt(FieldType.timewindow_8);
const t_twbig = @backingInt(FieldType.timewindow_big);
const t_string = @backingInt(FieldType.string);

test "skip: each field type takes its bits" {
    const gpa = testing.allocator;
    const fields = [_]Field{
        .init(t_byte, 5, "b"),
        .init(t_short | signed_flag, 12, "s"),
        .init(t_float, 20, "f"),
        .init(t_int | signed_flag, 32, "i"),
        .init(t_angle, 16, "a"),
        .init(t_tw8, 99, "tw8"), // bits ignored: always 8
        .init(t_twbig, 10, "twbig"),
        .init(t_string, 1, "str"),
    };
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try writeMask(&w, gpa, &.{ 0, 1, 2, 3, 4, 5, 6, 7 });
    try w.bits(gpa, 31, 5);
    try w.sbits(gpa, -2047, 12);
    try w.bits(gpa, 0xfffff, 20);
    try w.sbits(gpa, -5, 32);
    try w.bits(gpa, 0xabcd, 16);
    try w.sbits(gpa, -100, 8);
    try w.sbits(gpa, 300, 10);
    try w.string(gpa, "models/player.mdl");
    const end = w.bit;
    try w.bits(gpa, 0b101, 3); // trailer
    var r: BitReader = .init(w.slice());
    try skip(&r, &fields);
    try testing.expectEqual(end, r.bit);
    try testing.expectEqual(@as(u32, 0b101), try r.readBits(3));
}

test "skip: absent fields take no bits" {
    const gpa = testing.allocator;
    const fields = [_]Field{
        .init(t_int, 32, "a"),
        .init(t_byte, 8, "b"),
        .init(t_string, 1, "c"),
    };
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try writeMask(&w, gpa, &.{1});
    try w.byte(gpa, 0x42);
    try w.bits(gpa, 1, 1);
    var r: BitReader = .init(w.slice());
    try skip(&r, &fields);
    try testing.expectEqual(@as(usize, 3 + 8 + 8), r.bit);

    // No mask bytes at all: just the 3-bit count.
    var w0: BitWriter = .{};
    defer w0.deinit(gpa);
    try writeMask(&w0, gpa, &.{});
    var r0: BitReader = .init(w0.slice());
    try skip(&r0, &fields);
    try testing.expectEqual(@as(usize, 3), r0.bit);
}

test "skip: fields past 32 use the second mask word" {
    const gpa = testing.allocator;
    var fields: [40]Field = @splat(.init(t_byte, 8, "x"));
    fields[39] = .init(t_short, 16, "last");
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try writeMask(&w, gpa, &.{39});
    try w.short(gpa, 0x1234);
    var r: BitReader = .init(w.slice());
    try skip(&r, &fields);
    try testing.expectEqual(@as(usize, 3 + 5 * 8 + 16), r.bit);
}

test "skip: mask bits for fields the table doesn't have are ignored" {
    const gpa = testing.allocator;
    const fields = [_]Field{.init(t_byte, 8, "only")};
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try writeMask(&w, gpa, &.{ 0, 5 });
    try w.byte(gpa, 1);
    var r: BitReader = .init(w.slice());
    try skip(&r, &fields);
    try testing.expectEqual(@as(usize, 3 + 8 + 8), r.bit);
}

test "skip: errors" {
    const gpa = testing.allocator;
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try writeMask(&w, gpa, &.{0});
    try w.long(gpa, 0);
    try w.long(gpa, 0);
    const cases = [_]struct { f: Field, err: Error }{
        .{ .f = .init(0x100, 8, "unknown"), .err = error.UnknownFieldType },
        .{ .f = .init(t_int, 33, "wide"), .err = error.BadFieldBits },
        .{ .f = .init(t_int | signed_flag, 0, "zero"), .err = error.BadFieldBits },
    };
    for (cases) |c| {
        var r: BitReader = .init(w.slice());
        try testing.expectError(c.err, skip(&r, &.{c.f}));
    }
    // Truncated value.
    var r: BitReader = .init(w.slice()[0..2]);
    try testing.expectError(error.EndOfBuffer, skip(&r, &.{.init(t_int, 32, "cut")}));
    // Unsigned with 0 bits reads nothing, like ReHLTV.
    var r2: BitReader = .init(w.slice());
    try skip(&r2, &.{.init(t_int, 0, "none")});
    try testing.expectEqual(@as(usize, 3 + 8), r2.bit);
}

/// Writes a field description the way the server does: delta against zeroes
/// with the meta table (fields 0, 1, 4, 5 sent; offset, size and
/// postmultiply left out).
fn writeFieldDescription(w: *BitWriter, gpa: std.mem.Allocator, flags: u32, name: []const u8, field_bits: u8, premultiply: f32) !void {
    try writeMask(w, gpa, &.{ 0, 1, 4, 5 });
    try w.long(gpa, flags);
    try w.string(gpa, name);
    try w.byte(gpa, field_bits);
    try w.long(gpa, @intFromFloat(premultiply * 4000));
}

test "readDescription: table from an svc_deltadescription body" {
    const gpa = testing.allocator;
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    for ("event_t") |c| try w.byte(gpa, c);
    try w.byte(gpa, 0);
    try w.short(gpa, 2);
    try writeFieldDescription(&w, gpa, t_int | signed_flag, "entindex", 11, 1);
    try writeFieldDescription(&w, gpa, t_float | signed_flag, "origin[0]", 22, 8);
    w.alignByte();
    try w.byte(gpa, 0x99); // next message

    var tables: Tables = .{};
    defer tables.deinit(gpa);
    var r: BitReader = .init(w.slice());
    try readDescription(gpa, &r, &tables);
    try testing.expectEqual(@as(u8, 0x99), try r.readByte());

    const fields = tables.get("EVENT_T").?;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("entindex", fields[0].name());
    try testing.expectEqual(FieldType.integer, fields[0].kind());
    try testing.expect(fields[0].isSigned());
    try testing.expectEqual(@as(u8, 11), fields[0].bits);
    try testing.expectEqualStrings("origin[0]", fields[1].name());
    try testing.expectEqual(FieldType.float, fields[1].kind());
    try testing.expectEqual(@as(u8, 22), fields[1].bits);
    try testing.expectEqual(@as(f32, 8), fields[1].premultiply);
    try testing.expectEqual(@as(?[]const Field, null), tables.get("clientdata_t"));
}

test "Tables: a new description replaces the old one" {
    const gpa = testing.allocator;
    var tables: Tables = .{};
    defer tables.deinit(gpa);
    try tables.put(gpa, "weapon_data_t", try gpa.dupe(Field, &.{.init(t_byte, 8, "a")}));
    try tables.put(gpa, "Weapon_Data_T", try gpa.dupe(Field, &.{ .init(t_byte, 8, "a"), .init(t_byte, 8, "b") }));
    try testing.expectEqual(@as(usize, 1), tables.entries.items.len);
    try testing.expectEqual(@as(usize, 2), tables.get("weapon_data_t").?.len);
}

test "readDescription: errors free everything" {
    const gpa = testing.allocator;
    var tables: Tables = .{};
    defer tables.deinit(gpa);
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.byte(gpa, 0); // empty name
    var r: BitReader = .init(w.slice());
    try testing.expectError(error.EmptyTableName, readDescription(gpa, &r, &tables));

    var w2: BitWriter = .{};
    defer w2.deinit(gpa);
    for ("x\x00") |c| try w2.byte(gpa, c);
    try w2.short(gpa, 3);
    try writeFieldDescription(&w2, gpa, t_int, "only_one", 8, 1);
    var r2: BitReader = .init(w2.slice());
    try testing.expectError(error.EndOfBuffer, readDescription(gpa, &r2, &tables));
    try testing.expectEqual(@as(?[]const Field, null), tables.get("x"));
}
