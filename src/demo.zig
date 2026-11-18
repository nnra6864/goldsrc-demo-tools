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

/// Frame types (ReHLTV `DemoCmd`). Any value not listed is read as a network
/// frame, like ReHLTV and the `dem` crate do.
pub const FrameType = enum(u8) {
    /// Network messages of the startup entry.
    network_startup = 0,
    /// Network messages of the normal entry.
    network = 1,
    start_time = 2,
    console_command = 3,
    client_data = 4,
    /// Ends the entry.
    next_section = 5,
    event = 6,
    weapon_anim = 7,
    sound = 8,
    demo_buffer = 9,
    _,

    /// True for frames that carry net messages.
    pub fn isNetwork(t: FrameType) bool {
        return switch (t) {
            .start_time, .console_command, .client_data, .next_section, .event, .weapon_anim, .sound, .demo_buffer => false,
            .network_startup, .network, _ => true,
        };
    }
};

/// Every frame starts with type u8, time f32, frame i32.
pub const frame_header_size = 9;
/// Bytes between a network frame's header and its message length:
/// demo info (436) and sequence info (7 x i32).
pub const network_info_size = 436 + 28;
/// Largest network message block (ReHLTV `MAX_POSSIBLE_MSG`).
pub const max_message_length = 65536;

/// One frame of the demo.
pub const Frame = struct {
    /// Directory entry (or section, without a directory) the frame is in.
    entry: u32,
    /// Index in the entry's frame list, counting every frame type.
    index: u32,
    /// File offset of the frame's type byte.
    offset: usize,
    type: FrameType,
    /// Demo time in seconds: the timeline for voice.
    time: f32,
    /// Engine frame number, as recorded.
    frame: i32,
    /// The payload after the frame header. For network frames, only the net
    /// message bytes. Borrowed from the demo bytes.
    data: []const u8,
};

/// Why a frame scan stopped before the end.
pub const ScanProblem = struct {
    kind: Kind,
    /// Entry and index the bad frame would have had.
    entry: u32,
    index: u32,
    /// File offset of the bad frame.
    offset: usize,
    /// Time of the last good frame (0 if none).
    last_time: f32,

    pub const Kind = enum {
        /// The file ends inside a frame. Expected for demos that were never
        /// finalized: a warning, not an error.
        truncated,
        /// A length field is negative or too big: the demo is corrupt here.
        bad_length,
        /// A directory entry ended at the end of the file with no next-section
        /// frame.
        missing_next_section,
    };

    /// True if this may have lost data beyond a cut-off last frame.
    pub fn isError(p: ScanProblem) bool {
        return p.kind == .bad_length;
    }

    pub fn describe(p: ScanProblem) []const u8 {
        return switch (p.kind) {
            .truncated => "the file ends inside a frame",
            .bad_length => "a frame has a bad length field",
            .missing_next_section => "the file ends without a next-section frame",
        };
    }
};

/// Iterates every frame of every entry, in file order of the entries.
///
/// With a directory, each entry's frames are read from the entry's offset up
/// to and including its next-section frame. Without one (or with an unusable
/// one), frames are read from `header_size` to the end of the file, and each
/// next-section frame starts a new entry.
pub const FrameIterator = struct {
    data: []const u8,
    directory: ?Directory,
    entry: u32 = 0,
    index: u32 = 0,
    pos: usize,
    done: bool = false,
    last_time: f32 = 0,
    /// Set when the scan stopped early. Check it after `next` returns null.
    problem: ?ScanProblem = null,
    /// Frames whose type is not 0..9 (read as network frames). Unusual;
    /// worth a warning.
    unusual_types: u32 = 0,

    pub fn init(data: []const u8, directory: ?Directory) FrameIterator {
        const start: usize = if (directory) |d| @intCast(d.entry(0).offset) else header_size;
        return .{ .data = data, .directory = directory, .pos = start };
    }

    /// The next frame, or null at the end (or on a problem: see `problem`).
    pub fn next(it: *FrameIterator) ?Frame {
        if (it.done) return null;
        if (it.pos == it.data.len) {
            it.done = true;
            // Without a directory the file may end anywhere between frames.
            if (it.directory != null) it.stop(.missing_next_section);
            return null;
        }
        const frame = it.readFrame() catch |err| {
            it.stop(switch (err) {
                error.EndOfBuffer => .truncated,
                error.BadLength => .bad_length,
            });
            return null;
        };
        it.last_time = frame.time;
        if (frame.type == .next_section) {
            it.entry += 1;
            it.index = 0;
            if (it.directory) |d| {
                if (it.entry >= d.count()) {
                    it.done = true;
                } else {
                    it.pos = @intCast(d.entry(it.entry).offset);
                }
            }
        } else {
            it.index += 1;
        }
        return frame;
    }

    fn stop(it: *FrameIterator, kind: ScanProblem.Kind) void {
        it.done = true;
        it.problem = .{ .kind = kind, .entry = it.entry, .index = it.index, .offset = it.pos, .last_time = it.last_time };
    }

    /// Reads the frame at `pos` and advances past it. On error `pos` is
    /// unchanged.
    fn readFrame(it: *FrameIterator) (bits.ByteReader.Error || error{BadLength})!Frame {
        var r: bits.ByteReader = .init(it.data);
        r.pos = it.pos;
        const frame_type: FrameType = @fromBackingInt(@intCast(try r.int(u8)));
        const time = try r.float();
        const engine_frame = try r.int(i32);
        const payload_start = r.pos;
        var data: []const u8 = undefined;
        switch (frame_type) {
            .start_time, .next_section => data = &.{},
            .console_command => data = try r.bytes(64),
            .client_data => data = try r.bytes(32),
            .event => data = try r.bytes(84),
            .weapon_anim => data = try r.bytes(8),
            .sound => {
                try r.skip(4); // channel
                const sample_len = try r.int(i32);
                if (sample_len < 0) return error.BadLength;
                try r.skip(@intCast(sample_len));
                try r.skip(16); // attenuation, volume, flags, pitch
                data = it.data[payload_start..r.pos];
            },
            .demo_buffer => {
                const len = try r.int(i32);
                if (len < 0) return error.BadLength;
                data = try r.bytes(@intCast(len));
            },
            .network_startup, .network, _ => {
                try r.skip(network_info_size);
                const len = try r.int(i32);
                if (len < 0 or len > max_message_length) return error.BadLength;
                data = try r.bytes(@intCast(len));
                if (@backingInt(frame_type) > 9) it.unusual_types += 1;
            },
        }
        const offset = it.pos;
        it.pos = r.pos;
        return .{
            .entry = it.entry,
            .index = it.index,
            .offset = offset,
            .type = frame_type,
            .time = time,
            .frame = engine_frame,
            .data = data,
        };
    }
};

/// An opened demo: header, and directory if usable. Borrows the bytes.
pub const Demo = struct {
    data: []const u8,
    header: Header,
    /// Null when there is no usable directory; frames are then read from
    /// `header_size` to the end of the file.
    directory: ?Directory,
    /// Why the directory is not used, if it isn't. `.missing` is normal for
    /// demos that were never finalized; anything else deserves a warning.
    directory_problem: ?DirectoryProblem,

    pub fn open(data: []const u8) Error!Demo {
        const header = try parseHeader(data);
        return switch (parseDirectory(data, header)) {
            .ok => |d| .{ .data = data, .header = header, .directory = d, .directory_problem = null },
            .unusable => |p| .{ .data = data, .header = header, .directory = null, .directory_problem = p },
        };
    }

    /// Iterates every frame from the start.
    pub fn frames(d: Demo) FrameIterator {
        return .init(d.data, d.directory);
    }
};

/// Writes a demo time with 6 decimals, like Rust's `{:.6}` (the reference
/// tool's format): the exact value of the f32, rounded half to even, with a
/// `-` for any negative value, even one that rounds to zero.
pub fn formatTime(w: *std.Io.Writer, t: f32) std.Io.Writer.Error!void {
    // 24-bit mantissa times 10^6 (= 2^6 * 15625, 14 bits) fits in an f64's
    // 53 bits: the product is exact, and so is the rounding below.
    const scaled = @abs(@as(f64, t)) * 1e6;
    var units = @floor(scaled);
    const rest = scaled - units;
    if (rest > 0.5 or (rest == 0.5 and @mod(units, 2) == 1)) units += 1;
    const micros: u64 = @intFromFloat(units);
    if (std.math.signbit(t) and !std.math.isNan(t)) try w.writeByte('-');
    try w.print("{d}.{d:0>6}", .{ micros / 1_000_000, micros % 1_000_000 });
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

/// Builds synthetic demos (no directory) for tests, here and in other files.
pub const TestDemo = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) !TestDemo {
        var d: TestDemo = .{};
        try d.buf.appendSlice(gpa, &testHeader(0));
        return d;
    }

    pub fn deinit(d: *TestDemo, gpa: std.mem.Allocator) void {
        d.buf.deinit(gpa);
    }

    fn int(d: *TestDemo, gpa: std.mem.Allocator, comptime T: type, v: T) !void {
        var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try d.buf.appendSlice(gpa, &b);
    }

    pub fn frame(d: *TestDemo, gpa: std.mem.Allocator, t: u8, time: f32, payload: []const u8) !void {
        try d.buf.append(gpa, t);
        try d.int(gpa, u32, @bitCast(time));
        try d.int(gpa, i32, 7);
        try d.buf.appendSlice(gpa, payload);
    }

    pub fn network(d: *TestDemo, gpa: std.mem.Allocator, t: u8, time: f32, msgs: []const u8) !void {
        try d.frame(gpa, t, time, &.{});
        try d.buf.appendNTimes(gpa, 0xaa, network_info_size);
        try d.int(gpa, i32, @intCast(msgs.len));
        try d.buf.appendSlice(gpa, msgs);
    }
};

test "FrameIterator: every frame type, no directory" {
    const gpa = testing.allocator;
    var d: TestDemo = try .init(gpa);
    defer d.deinit(gpa);
    try d.network(gpa, 0, 0, "startup");
    try d.frame(gpa, 5, 0, &.{});
    try d.frame(gpa, 2, 0.5, &.{});
    try d.frame(gpa, 3, 1, &@as([64]u8, @splat('c')));
    try d.frame(gpa, 4, 1, &@as([32]u8, @splat(4)));
    try d.frame(gpa, 6, 1, &@as([84]u8, @splat(6)));
    try d.frame(gpa, 7, 1, &@as([8]u8, @splat(7)));
    // sound: channel, sample length 3, "abc", 16 bytes
    try d.frame(gpa, 8, 1, &([_]u8{ 1, 0, 0, 0, 3, 0, 0, 0, 'a', 'b', 'c' } ++ @as([16]u8, @splat(0))));
    try d.frame(gpa, 9, 1, &.{ 2, 0, 0, 0, 'x', 'y' });
    try d.network(gpa, 1, 2.5, "net");
    try d.network(gpa, 42, 3, "odd");

    var it: FrameIterator = .init(d.buf.items, null);
    const want = [_]struct { entry: u32, index: u32, t: u8, len: usize }{
        .{ .entry = 0, .index = 0, .t = 0, .len = 7 },
        .{ .entry = 0, .index = 1, .t = 5, .len = 0 },
        .{ .entry = 1, .index = 0, .t = 2, .len = 0 },
        .{ .entry = 1, .index = 1, .t = 3, .len = 64 },
        .{ .entry = 1, .index = 2, .t = 4, .len = 32 },
        .{ .entry = 1, .index = 3, .t = 6, .len = 84 },
        .{ .entry = 1, .index = 4, .t = 7, .len = 8 },
        .{ .entry = 1, .index = 5, .t = 8, .len = 4 + 4 + 3 + 16 },
        .{ .entry = 1, .index = 6, .t = 9, .len = 2 },
        .{ .entry = 1, .index = 7, .t = 1, .len = 3 },
        .{ .entry = 1, .index = 8, .t = 42, .len = 3 },
    };
    for (want) |w| {
        const f = it.next() orelse return error.TestUnexpectedNull;
        try testing.expectEqual(w.entry, f.entry);
        try testing.expectEqual(w.index, f.index);
        try testing.expectEqual(w.t, @backingInt(f.type));
        try testing.expectEqual(w.len, f.data.len);
        try testing.expectEqual(@as(i32, 7), f.frame);
    }
    try testing.expectEqual(@as(?Frame, null), it.next());
    try testing.expectEqual(@as(?ScanProblem, null), it.problem);
    try testing.expectEqual(@as(u32, 1), it.unusual_types);
    try testing.expect(FrameType.isNetwork(@fromBackingInt(@intCast(42))));
}

test "FrameIterator: net message bytes and time" {
    const gpa = testing.allocator;
    var d: TestDemo = try .init(gpa);
    defer d.deinit(gpa);
    try d.network(gpa, 1, 12.25, &.{ 53, 0, 3, 0, 1, 2, 3 });
    var it: FrameIterator = .init(d.buf.items, null);
    const f = it.next().?;
    try testing.expectEqual(FrameType.network, f.type);
    try testing.expectEqual(@as(f32, 12.25), f.time);
    try testing.expectEqual(@as(usize, header_size), f.offset);
    try testing.expectEqualSlices(u8, &.{ 53, 0, 3, 0, 1, 2, 3 }, f.data);
}

test "FrameIterator: a cut-off last frame ends the scan with a warning" {
    const gpa = testing.allocator;
    var d: TestDemo = try .init(gpa);
    defer d.deinit(gpa);
    try d.network(gpa, 1, 1, "ok");
    const good_end = d.buf.items.len;
    try d.network(gpa, 1, 2, "cut off here");
    // Every possible cut inside the second frame.
    for (good_end + 1..d.buf.items.len) |end| {
        var it: FrameIterator = .init(d.buf.items[0..end], null);
        try testing.expect(it.next() != null);
        try testing.expectEqual(@as(?Frame, null), it.next());
        const p = it.problem.?;
        try testing.expectEqual(ScanProblem.Kind.truncated, p.kind);
        try testing.expectEqual(good_end, p.offset);
        try testing.expectEqual(@as(u32, 1), p.index);
        try testing.expectEqual(@as(f32, 1), p.last_time);
        try testing.expect(!p.isError());
    }
}

test "FrameIterator: bad lengths are errors" {
    const gpa = testing.allocator;
    const cases = [_]struct { t: u8, payload: []const u8 }{
        .{ .t = 9, .payload = &.{ 0xff, 0xff, 0xff, 0xff } },
        .{ .t = 8, .payload = &.{ 0, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff } },
        .{ .t = 1, .payload = &(@as([network_info_size]u8, @splat(0)) ++ [_]u8{ 0xff, 0xff, 0xff, 0xff }) },
        .{ .t = 1, .payload = &(@as([network_info_size]u8, @splat(0)) ++ [_]u8{ 0x01, 0x00, 0x01, 0x00 }) },
    };
    for (cases) |c| {
        var d: TestDemo = try .init(gpa);
        defer d.deinit(gpa);
        try d.frame(gpa, c.t, 0, c.payload);
        try d.buf.appendNTimes(gpa, 0, 70000);
        var it: FrameIterator = .init(d.buf.items, null);
        try testing.expectEqual(@as(?Frame, null), it.next());
        try testing.expectEqual(ScanProblem.Kind.bad_length, it.problem.?.kind);
        try testing.expect(it.problem.?.isError());
    }
}

test "truncated-no-directory.dem: scanned from 544 to a cut-off last frame" {
    const gpa = testing.allocator;
    const data = try testdata.readFixture(gpa, "truncated-no-directory", ".dem");
    defer gpa.free(data);
    const demo: Demo = try .open(data);
    try testing.expectEqual(@as(?Directory, null), demo.directory);
    try testing.expectEqual(@as(?DirectoryProblem, .missing), demo.directory_problem);

    var it = demo.frames();
    var first: ?Frame = null;
    var last: Frame = undefined;
    var per_entry = [_]u32{ 0, 0 };
    while (it.next()) |f| {
        if (first == null) first = f;
        last = f;
        try testing.expect(f.entry < 2);
        per_entry[f.entry] += 1;
    }
    try testing.expectEqual(@as(usize, header_size), first.?.offset);
    // Startup: one network frame and the next-section frame.
    try testing.expectEqual(@as(u32, 2), per_entry[0]);
    const p = it.problem.?;
    try testing.expectEqual(ScanProblem.Kind.truncated, p.kind);
    try testing.expect(!p.isError());
    try testing.expectEqual(@as(u32, 1), p.entry);
    try testing.expectEqual(per_entry[1], p.index);
    try testing.expect(p.offset > last.offset and p.offset < data.len);
    // About 12 minutes.
    try testing.expect(last.time > 700 and last.time < 760);
}

/// Count of message `name` in `testdata/<base>.messages.tsv`.
fn messageCount(gpa: std.mem.Allocator, base: []const u8, name: []const u8) !u32 {
    const text = try testdata.readFixture(gpa, base, ".messages.tsv");
    defer gpa.free(text);
    var it: testdata.TsvIterator = .init(text);
    while (try it.next()) |row| {
        if (std.mem.eql(u8, row[0], name)) return std.fmt.parseInt(u32, row[1], 10);
    }
    return error.MessageNotListed;
}

test "test demos iterate to the end; SvcTime count matches network frames" {
    const gpa = testing.allocator;
    for (testdata.demos) |base| {
        const data = try testdata.readFixture(gpa, base, ".dem");
        defer gpa.free(data);
        const demo: Demo = try .open(data);
        var it = demo.frames();
        var network = [_]u32{ 0, 0 };
        var next_sections: u32 = 0;
        var last_time: f32 = -1;
        while (it.next()) |f| {
            try testing.expect(f.entry < 2);
            if (f.type.isNetwork()) network[f.entry] += 1;
            if (f.type == .next_section) next_sections += 1;
            // Time never goes backwards by more than float noise.
            try testing.expect(f.time >= last_time - 0.001);
            last_time = f.time;
        }
        try testing.expectEqual(@as(u32, 0), it.unusual_types);
        try testing.expectEqual(@as(u32, 1), network[0]);
        // One svc_time per network frame, startup frame included, except the
        // last frame of a finalized demo (checked per frame in messages.zig).
        const svc_time = try messageCount(gpa, base, "SvcTime");
        const total = network[0] + network[1];
        try testing.expectEqual(if (demo.directory != null) total - 1 else total, svc_time);
        if (demo.directory) |dir| {
            // Finalized: ends exactly where the directory starts.
            try testing.expectEqual(@as(?ScanProblem, null), it.problem);
            try testing.expectEqual(@as(u32, 2), next_sections);
            try testing.expectEqual(@as(usize, @intCast(demo.header.directory_offset)), it.pos);
            try testing.expectEqual(dir.entry(1).frame_count, @as(i32, @intCast(network[1])));
        } else {
            try testing.expectEqual(ScanProblem.Kind.truncated, it.problem.?.kind);
            try testing.expectEqual(@as(u32, 1), next_sections);
        }
    }
}

test "formatTime: exact value, half to even, negative zero" {
    const cases = [_]struct { t: f32, want: []const u8 }{
        .{ .t = 0, .want = "0.000000" },
        .{ .t = -3.793335068280612e-08, .want = "-0.000000" },
        .{ .t = 0.429078, .want = "0.429078" },
        // The f32 nearest 85.6232376 is 85.62323760986328: 85.623238, not 85.623240.
        .{ .t = 85.62323760986328, .want = "85.623238" },
        // Exact ties go to even.
        .{ .t = 125.0703125, .want = "125.070312" },
        .{ .t = 0.0078125, .want = "0.007812" },
        .{ .t = 0.0234375, .want = "0.023438" },
        .{ .t = 1234.5, .want = "1234.500000" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try formatTime(&w, c.t);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}
