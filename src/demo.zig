//! GoldSrc demo container: header, directory and frames (doc/FORMAT.md,
//! ReHLTV `common/DemoFile.cpp`). Knows nothing about net messages.

const std = @import("std");
const bits = @import("bits.zig");

/// The header is the first 544 bytes; frames of the first entry follow it.
pub const header_size = 544;
/// Largest directory ReHLTV accepts (`MAX_DEMO_ENTRY`).
pub const max_entries = 1024;
/// Size of one directory entry on disk.
pub const entry_size = 92;

pub const Error = error{
    /// Shorter than a header, or no `HLDEMO` magic.
    NotADemo,
};

/// The demo header (offset 0).
pub const Header = struct {
    demo_protocol: i32,
    net_protocol: i32,
    /// Borrowed from the demo bytes.
    map_name: []const u8,
    /// Borrowed from the demo bytes, e.g. `cstrike`.
    game_dir: []const u8,
    map_crc: u32,
    /// 0 when the demo was never finalized (crash, HLTV killed).
    directory_offset: i32,

    /// Demo protocol this parser is written for.
    pub const demo_protocol_expected = 5;
    /// Net protocol this parser is written for.
    pub const net_protocol_expected = 48;
};

/// Parses the header. Only a missing magic or a too-short file is an error;
/// other protocol versions are left to the caller to warn about.
pub fn parseHeader(data: []const u8) Error!Header {
    if (data.len < header_size) return error.NotADemo;
    const h = data[0..header_size];
    if (!std.mem.eql(u8, h[0..7], "HLDEMO\x00")) return error.NotADemo;
    return .{
        .demo_protocol = le(i32, h, 8),
        .net_protocol = le(i32, h, 12),
        .map_name = cutNul(h[16..276]),
        .game_dir = cutNul(h[276..536]),
        .map_crc = le(u32, h, 536),
        .directory_offset = le(i32, h, 540),
    };
}

/// Little-endian `T` at a comptime offset of a fixed-size record: no failure
/// path, the bounds are checked at compile time.
fn le(comptime T: type, record: anytype, comptime offset: usize) T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, record[offset..][0..n], .little);
}

/// The part of a NUL-padded field before the first NUL.
fn cutNul(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

/// Entry types.
pub const EntryType = enum(i32) {
    /// Signon data needed to spawn into the server.
    startup = 0,
    /// The game itself.
    normal = 1,
    _,
};

/// One directory entry: a section of frames.
pub const Entry = struct {
    type: EntryType,
    /// Borrowed from the demo bytes (`LOADING`, `Playback`).
    description: []const u8,
    flags: i32,
    cd_track: i32,
    track_time: f32,
    /// As written by the recorder. Counts network frames only in HLTV demos;
    /// don't rely on it.
    frame_count: i32,
    /// File offset of the entry's first frame.
    offset: i32,
    length: i32,
};

/// Why a demo's directory can't be used.
pub const DirectoryProblem = enum {
    /// Offset 0: the demo was never finalized. Not unusual after a crash.
    missing,
    /// The offset points outside the file.
    offset_out_of_range,
    /// The entry count is not in 1..1024.
    bad_entry_count,
    /// The entries don't fit in the file.
    truncated,
    /// An entry's frame offset points outside the file or into the header.
    bad_entry_offset,

    pub fn describe(p: DirectoryProblem) []const u8 {
        return switch (p) {
            .missing => "no directory (demo not finalized)",
            .offset_out_of_range => "directory offset is outside the file",
            .bad_entry_count => "directory entry count is not in 1..1024",
            .truncated => "directory entries run past the end of the file",
            .bad_entry_offset => "a directory entry points outside the file",
        };
    }
};

/// The directory, read lazily from the demo bytes.
pub const Directory = struct {
    /// The raw entries, `count * entry_size` bytes.
    raw: []const u8,

    pub fn count(d: Directory) usize {
        return d.raw.len / entry_size;
    }

    /// Entry `i` (< `count()`).
    pub fn entry(d: Directory, i: usize) Entry {
        const e = d.raw[i * entry_size ..][0..entry_size];
        return .{
            .type = @fromBackingInt(@intCast(le(i32, e, 0))),
            .description = cutNul(e[4..68]),
            .flags = le(i32, e, 68),
            .cd_track = le(i32, e, 72),
            .track_time = @bitCast(le(u32, e, 76)),
            .frame_count = le(i32, e, 80),
            .offset = le(i32, e, 84),
            .length = le(i32, e, 88),
        };
    }
};

/// The directory, or why there is none usable. Without a directory, frames
/// are read from `header_size` to the end of the file.
pub const DirectoryResult = union(enum) {
    ok: Directory,
    unusable: DirectoryProblem,
};

/// Reads the directory the header points to.
pub fn parseDirectory(data: []const u8, header: Header) DirectoryResult {
    if (header.directory_offset == 0) return .{ .unusable = .missing };
    if (header.directory_offset < header_size or header.directory_offset >= data.len)
        return .{ .unusable = .offset_out_of_range };
    var r: bits.ByteReader = .init(data[@intCast(header.directory_offset)..]);
    const n = r.int(i32) catch return .{ .unusable = .offset_out_of_range };
    if (n < 1 or n > max_entries) return .{ .unusable = .bad_entry_count };
    const raw = r.bytes(@as(usize, @intCast(n)) * entry_size) catch return .{ .unusable = .truncated };
    const dir: Directory = .{ .raw = raw };
    for (0..dir.count()) |i| {
        const off = dir.entry(i).offset;
        if (off < header_size or off >= data.len) return .{ .unusable = .bad_entry_offset };
    }
    return .{ .ok = dir };
}

const testing = std.testing;
const testdata = @import("testdata.zig");

/// A synthetic header for tests.
fn testHeader(directory_offset: i32) [header_size]u8 {
    var h: [header_size]u8 = @splat(0);
    @memcpy(h[0..8], "HLDEMO\x00\x00");
    std.mem.writeInt(i32, h[8..12], 5, .little);
    std.mem.writeInt(i32, h[12..16], 48, .little);
    @memcpy(h[16..24], "de_dust2");
    @memcpy(h[276..283], "cstrike");
    std.mem.writeInt(u32, h[536..540], 0xdeadbeef, .little);
    std.mem.writeInt(i32, h[540..544], directory_offset, .little);
    return h;
}

test "parseHeader: synthetic header" {
    const h = testHeader(1234);
    const header = try parseHeader(&h);
    try testing.expectEqual(@as(i32, 5), header.demo_protocol);
    try testing.expectEqual(@as(i32, 48), header.net_protocol);
    try testing.expectEqualStrings("de_dust2", header.map_name);
    try testing.expectEqualStrings("cstrike", header.game_dir);
    try testing.expectEqual(@as(u32, 0xdeadbeef), header.map_crc);
    try testing.expectEqual(@as(i32, 1234), header.directory_offset);
}

test "parseHeader: rejects short files and bad magic" {
    var h = testHeader(0);
    try testing.expectError(error.NotADemo, parseHeader(h[0 .. header_size - 1]));
    h[0] = 'X';
    try testing.expectError(error.NotADemo, parseHeader(&h));
}

test "parseDirectory: problems" {
    var buf: [header_size + 4 + entry_size]u8 = @splat(0);
    @memcpy(buf[0..header_size], &testHeader(0));
    try testing.expectEqual(DirectoryResult{ .unusable = .missing }, parseDirectory(&buf, try parseHeader(&buf)));

    var header = try parseHeader(&buf);
    header.directory_offset = @intCast(buf.len);
    try testing.expectEqual(DirectoryResult{ .unusable = .offset_out_of_range }, parseDirectory(&buf, header));
    header.directory_offset = 100;
    try testing.expectEqual(DirectoryResult{ .unusable = .offset_out_of_range }, parseDirectory(&buf, header));

    header.directory_offset = header_size;
    std.mem.writeInt(i32, buf[header_size..][0..4], 0, .little);
    try testing.expectEqual(DirectoryResult{ .unusable = .bad_entry_count }, parseDirectory(&buf, header));
    std.mem.writeInt(i32, buf[header_size..][0..4], 1025, .little);
    try testing.expectEqual(DirectoryResult{ .unusable = .bad_entry_count }, parseDirectory(&buf, header));
    std.mem.writeInt(i32, buf[header_size..][0..4], 2, .little);
    try testing.expectEqual(DirectoryResult{ .unusable = .truncated }, parseDirectory(&buf, header));

    // One entry pointing into the header.
    std.mem.writeInt(i32, buf[header_size..][0..4], 1, .little);
    try testing.expectEqual(DirectoryResult{ .unusable = .bad_entry_offset }, parseDirectory(&buf, header));
}

test "header and directory of the test demos" {
    const gpa = testing.allocator;
    for (testdata.demos) |base| {
        const data = try testdata.readFixture(gpa, base, ".dem");
        defer gpa.free(data);
        const header = try parseHeader(data);
        try testing.expectEqual(@as(i32, 5), header.demo_protocol);
        try testing.expectEqual(@as(i32, 48), header.net_protocol);
        try testing.expectEqualStrings("cstrike", header.game_dir);
        switch (parseDirectory(data, header)) {
            .unusable => |p| {
                try testing.expectEqualStrings("truncated-no-directory", base);
                try testing.expectEqual(DirectoryProblem.missing, p);
            },
            .ok => |dir| {
                try testing.expectEqual(@as(usize, 2), dir.count());
                const startup = dir.entry(0);
                try testing.expectEqual(EntryType.startup, startup.type);
                try testing.expectEqualStrings("LOADING", startup.description);
                try testing.expectEqual(@as(i32, header_size), startup.offset);
                const normal = dir.entry(1);
                try testing.expectEqual(EntryType.normal, normal.type);
                try testing.expectEqualStrings("Playback", normal.description);
                // Entries are contiguous and the directory follows the last one.
                try testing.expectEqual(startup.offset + startup.length, normal.offset);
                try testing.expectEqual(header.directory_offset, normal.offset + normal.length);
            },
        }
    }
}
