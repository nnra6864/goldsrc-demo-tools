//! `repair`: finishes a demo that HLTV never closed (server crash, HLTV or
//! the container killed), so the game can play it. Writes what ReHLTV's
//! `DemoFile::CloseFile` would have (doc/FORMAT.md "Repair"): the game
//! entry's next-section frame, the two-entry directory, and the directory
//! offset in the header. A cut-off last frame is dropped; nothing else
//! changes.

const std = @import("std");
const demo = @import("demo.zig");

/// Why a demo can't be repaired, or doesn't need it.
pub const Problem = enum {
    /// It has a usable directory already.
    complete,
    /// Its directory offset isn't 0 but the directory is unusable: the file
    /// is not just unfinished, and rewriting it could lose more.
    broken_directory,
    /// A frame has a bad length: the frames after it can't be found.
    corrupt,
    /// It ends before the game entry starts (crashed while connecting).
    no_game_entry,

    pub fn describe(p: Problem) []const u8 {
        return switch (p) {
            .complete => "the demo is complete already, nothing to do",
            .broken_directory => "the directory is broken but the demo was finished: not repairing it",
            .corrupt => "a frame has a bad length, so the frames after it can't be found: not repairing it",
            .no_game_entry => "the demo ends before the game starts: nothing to play",
        };
    }
};

/// What to write.
pub const Plan = struct {
    /// Bytes of the input kept: header through the last complete frame.
    keep: usize,
    /// Bytes of a cut-off last frame dropped.
    dropped: usize,
    /// Length of the startup entry (from `demo.header_size`).
    startup_length: u32,
    /// Offset of the game entry.
    game_offset: u32,
    /// Network frames in the game entry: HLTV's frame count.
    frames: i32,
    /// Time of the last frame.
    time: f32,
    /// The last kept frame is already the game entry's next-section frame
    /// (HLTV died while writing the directory).
    has_end: bool,

    /// Directory offset: right after the game entry's next-section frame.
    pub fn directoryOffset(p: Plan) usize {
        return p.keep + @as(usize, if (p.has_end) 0 else demo.frame_header_size);
    }

    /// Size of the repaired demo.
    pub fn size(p: Plan) usize {
        return p.directoryOffset() + 4 + 2 * demo.entry_size;
    }
};

pub const Result = union(enum) {
    repair: Plan,
    cannot: Problem,
};

/// Works out how to finish `d`.
pub fn plan(d: demo.Demo) Result {
    if (d.directory != null) return .{ .cannot = .complete };
    if (d.directory_problem.? != .missing) return .{ .cannot = .broken_directory };
    var it = d.frames();
    var keep: usize = demo.header_size;
    var startup_end: ?usize = null;
    var frames: i32 = 0;
    var time: f32 = 0;
    var has_end = false;
    while (it.next()) |f| {
        switch (f.entry) {
            0 => if (f.type == .next_section) {
                startup_end = it.pos;
            },
            1 => if (f.type == .next_section) {
                has_end = true;
            } else if (f.type == .network) {
                frames += 1;
            },
            else => unreachable, // the loop stops at the end of entry 1
        }
        keep = it.pos;
        time = f.time;
        // What follows the game entry's next-section frame is the directory
        // HLTV was writing: drop it, it is written anew.
        if (has_end) break;
    }
    if (!has_end) if (it.problem) |p| if (p.isError()) return .{ .cannot = .corrupt };
    const game_offset = startup_end orelse return .{ .cannot = .no_game_entry };
    if (keep == game_offset) return .{ .cannot = .no_game_entry };
    return .{ .repair = .{
        .keep = keep,
        .dropped = d.data.len - keep,
        .startup_length = @intCast(game_offset - demo.header_size),
        .game_offset = @intCast(game_offset),
        .frames = frames,
        .time = time,
        .has_end = has_end,
    } };
}

/// Writes the repaired demo.
pub fn write(w: *std.Io.Writer, data: []const u8, p: Plan) std.Io.Writer.Error!void {
    var header = data[0..demo.header_size].*;
    const dir: i32 = @intCast(p.directoryOffset());
    std.mem.writeInt(i32, header[540..544], dir, .little);
    try w.writeAll(&header);
    try w.writeAll(data[demo.header_size..p.keep]);
    if (!p.has_end) {
        try w.writeByte(@backingInt(demo.FrameType.next_section));
        try w.writeInt(u32, @bitCast(p.time), .little);
        try w.writeInt(i32, p.frames, .little);
    }
    try w.writeInt(i32, 2, .little);
    try entry(w, .startup, "LOADING", 0, 0, demo.header_size, p.startup_length);
    try entry(w, .normal, "Playback", p.time, p.frames, p.game_offset, @intCast(dir - @as(i32, @intCast(p.game_offset))));
}

/// One directory entry, `demoentry_t`: type, description[64], flags,
/// CD track, track time, frames, offset, length.
fn entry(w: *std.Io.Writer, t: demo.EntryType, description: []const u8, time: f32, frames: i32, offset: u32, length: u32) std.Io.Writer.Error!void {
    var desc: [64]u8 = @splat(0);
    @memcpy(desc[0..description.len], description);
    try w.writeInt(i32, @backingInt(t), .little);
    try w.writeAll(&desc);
    try w.writeInt(i32, 0, .little); // flags
    try w.writeInt(i32, 0, .little); // CD track
    try w.writeInt(u32, @bitCast(time), .little);
    try w.writeInt(i32, frames, .little);
    try w.writeInt(u32, offset, .little);
    try w.writeInt(u32, length, .little);
}

const testing = std.testing;
const testdata = @import("testdata.zig");

/// Repairs `data` into a new buffer. Caller frees.
fn repaired(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const d = try demo.Demo.open(data);
    const p = switch (plan(d)) {
        .repair => |p| p,
        .cannot => |c| {
            std.debug.print("cannot: {t}\n", .{c});
            return error.TestCannotRepair;
        },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(&out.writer, data, p);
    try testing.expectEqual(p.size(), out.written().len);
    return out.toOwnedSlice();
}

/// `data` as HLTV would have left it if killed just before closing the file:
/// without the game entry's next-section frame and the directory, and with
/// directory offset 0. Caller frees.
fn unfinished(gpa: std.mem.Allocator, data: []const u8, tail: []const u8) ![]u8 {
    const d = try demo.Demo.open(data);
    const end: usize = @intCast(d.header.directory_offset);
    const out = try std.mem.concat(gpa, u8, &.{ data[0 .. end - demo.frame_header_size], tail });
    std.mem.writeInt(i32, out[540..544], 0, .little);
    return out;
}

test "repair: an unfinished demo comes back byte for byte as HLTV finished it" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "one-player", "rejoin-team-switch" }) |base| {
        const original = try testdata.readFixture(gpa, base, ".dem");
        defer gpa.free(original);
        // Killed between frames, and killed in the middle of one (the first
        // 30 bytes of a network frame).
        const d = try demo.Demo.open(original);
        var it = d.frames();
        const net = while (it.next()) |f| {
            if (f.type == .network) break f;
        } else unreachable;
        for ([_][]const u8{ "", original[net.offset..][0..30] }) |tail| {
            const cut = try unfinished(gpa, original, tail);
            defer gpa.free(cut);
            const fixed = try repaired(gpa, cut);
            defer gpa.free(fixed);
            try testing.expectEqualSlices(u8, original, fixed);
        }
    }
}

test "repair: a demo that died while writing the directory" {
    const gpa = testing.allocator;
    const original = try testdata.readFixture(gpa, "one-player", ".dem");
    defer gpa.free(original);
    const d = try demo.Demo.open(original);
    const end: usize = @intCast(d.header.directory_offset);
    // The next-section frame made it, half of the directory didn't.
    const cut = try gpa.dupe(u8, original[0 .. end + 50]);
    defer gpa.free(cut);
    std.mem.writeInt(i32, cut[540..544], 0, .little);
    const fixed = try repaired(gpa, cut);
    defer gpa.free(fixed);
    try testing.expectEqualSlices(u8, original, fixed);
}

test "repair: the killed test demo becomes a complete one with the same frames" {
    const gpa = testing.allocator;
    const data = try testdata.readFixture(gpa, "truncated-no-directory", ".dem");
    defer gpa.free(data);
    const fixed = try repaired(gpa, data);
    defer gpa.free(fixed);
    const before = try demo.Demo.open(data);
    const after = try demo.Demo.open(fixed);
    try testing.expect(after.directory != null);
    try testing.expectEqual(@as(usize, 2), after.directory.?.count());
    var a = before.frames();
    var b = after.frames();
    var n: usize = 0;
    while (a.next()) |fa| : (n += 1) {
        const fb = b.next().?;
        try testing.expectEqual(fa.type, fb.type);
        try testing.expectEqual(fa.time, fb.time);
        try testing.expectEqualSlices(u8, fa.data, fb.data);
    }
    // The repaired one has the added next-section frame, then ends cleanly.
    try testing.expectEqual(demo.FrameType.next_section, b.next().?.type);
    try testing.expectEqual(@as(?demo.Frame, null), b.next());
    try testing.expectEqual(@as(?demo.ScanProblem, null), b.problem);
    try testing.expect(n > 1000);
}

test "repair: what it refuses" {
    const gpa = testing.allocator;
    const original = try testdata.readFixture(gpa, "one-player", ".dem");
    defer gpa.free(original);
    try testing.expectEqual(Result{ .cannot = .complete }, plan(try .open(original)));

    // Directory offset pointing nowhere: finished, then damaged.
    const broken = try gpa.dupe(u8, original);
    defer gpa.free(broken);
    std.mem.writeInt(i32, broken[540..544], 0x7fffffff, .little);
    try testing.expectEqual(Result{ .cannot = .broken_directory }, plan(try .open(broken)));

    // Killed during the startup entry.
    const d = try demo.Demo.open(original);
    const startup = d.directory.?.entry(0);
    const early = try gpa.dupe(u8, original[0..@intCast(startup.offset + 20)]);
    defer gpa.free(early);
    std.mem.writeInt(i32, early[540..544], 0, .little);
    try testing.expectEqual(Result{ .cannot = .no_game_entry }, plan(try .open(early)));

    // A negative message length in the middle.
    const corrupt = try unfinished(gpa, original, "");
    defer gpa.free(corrupt);
    var it = (try demo.Demo.open(corrupt)).frames();
    const net = while (it.next()) |f| {
        if (f.entry == 1 and f.type == .network) break f;
    } else unreachable;
    std.mem.writeInt(i32, corrupt[net.offset + demo.frame_header_size + demo.network_info_size ..][0..4], -1, .little);
    try testing.expectEqual(Result{ .cannot = .corrupt }, plan(try .open(corrupt)));
}
