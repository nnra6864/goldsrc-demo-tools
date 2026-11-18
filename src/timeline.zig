//! Places decoded voice on per-track timelines (DESIGN.md "Timeline").
//! Each packet lands at its frame's demo time, or right after the player's
//! previous audio if that would overlap (packets arrive in bursts).

const std = @import("std");
const players = @import("players.zig");
const steamvoice = @import("steamvoice.zig");
const opus = @import("opus.zig");

pub const sample_rate = steamvoice.sample_rate;

/// A packet that could not be decoded: its audio is missing.
pub const LostPacket = struct {
    /// Borrowed from the player.
    player: []const u8,
    time: f32,
    err: anyerror,
};

/// What went wrong while rendering, for the report.
pub const Report = struct {
    lost: std.ArrayList(LostPacket) = .empty,
    /// Packets decoded despite a bad CRC.
    bad_crc: u32 = 0,
    /// Frames concealed with PLC.
    concealed: u32 = 0,

    pub fn deinit(r: *Report, gpa: std.mem.Allocator) void {
        r.lost.deinit(gpa);
    }
};

/// Samples in a timeline for a demo of `duration` seconds (one second of
/// slack at the end, like the Rust tool).
pub fn length(duration: f32) usize {
    return @intFromFloat((@as(f64, @max(duration, 0)) + 1.0) * sample_rate);
}

/// Sample index for demo time `t`.
fn sampleAt(t: f32) usize {
    return @intFromFloat(@max(@as(f64, t), 0) * sample_rate);
}

/// Decodes `player`'s packets and adds them onto `pcm` (mixing).
pub fn addPlayer(gpa: std.mem.Allocator, pcm: []f32, player: *const players.Player, report: *Report) !void {
    var dec: opus.VoiceDecoder = try .init();
    defer dec.deinit();
    var samples: std.ArrayList(f32) = .empty;
    defer samples.deinit(gpa);
    var cursor: usize = 0;
    for (player.packets.items) |pkt| {
        samples.clearRetainingCapacity();
        const parsed = steamvoice.parse(pkt.data) catch |err| {
            try report.lost.append(gpa, .{ .player = player.name, .time = pkt.time, .err = err });
            continue;
        };
        if (!parsed.crc_ok) report.bad_crc += 1;
        dec.decode(gpa, parsed, &samples) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try report.lost.append(gpa, .{ .player = player.name, .time = pkt.time, .err = err });
                continue;
            },
        };
        const at = @max(sampleAt(pkt.time), cursor);
        if (at < pcm.len) {
            const n = @min(samples.items.len, pcm.len - at);
            for (pcm[at..][0..n], samples.items[0..n]) |*o, s| o.* += s;
        }
        cursor = at + samples.items.len;
    }
    report.concealed += dec.concealed;
}

/// Renders a track: all its players mixed onto one timeline of `len`
/// samples. Caller frees.
pub fn renderTrack(gpa: std.mem.Allocator, track: players.Track, len: usize, report: *Report) ![]f32 {
    const pcm = try gpa.alloc(f32, len);
    errdefer gpa.free(pcm);
    @memset(pcm, 0);
    for (track.players) |pl| try addPlayer(gpa, pcm, pl, report);
    return pcm;
}

/// A stretch of sound, in seconds.
pub const Interval = struct { start: f64, end: f64 };

/// Sound intervals the way ffmpeg `silencedetect` finds them: silence is a
/// run of samples below `noise_db` lasting at least `min_silence` seconds;
/// everything between silences is sound. Caller frees.
pub fn speechIntervals(gpa: std.mem.Allocator, pcm: []const f32, rate: u32, noise_db: f64, min_silence: f64) ![]Interval {
    const threshold: f32 = @floatCast(std.math.pow(f64, 10, noise_db / 20));
    const min_run: usize = @intFromFloat(min_silence * @as(f64, @floatFromInt(rate)));
    const r: f64 = @floatFromInt(rate);
    var out: std.ArrayList(Interval) = .empty;
    errdefer out.deinit(gpa);
    var sound_start: ?usize = 0; // a sound interval starts at 0 unless silence does
    var quiet_from: usize = 0;
    var quiet = false;
    for (pcm, 0..) |s, i| {
        if (@abs(s) < threshold) {
            if (!quiet) {
                quiet = true;
                quiet_from = i;
            }
            if (i + 1 - quiet_from == min_run) {
                // The quiet run became a silence: close the sound before it.
                if (sound_start) |st| {
                    if (quiet_from > st) try out.append(gpa, .{ .start = @as(f64, @floatFromInt(st)) / r, .end = @as(f64, @floatFromInt(quiet_from)) / r });
                }
                sound_start = null;
            }
        } else {
            if (quiet and sound_start == null) sound_start = i;
            quiet = false;
        }
    }
    if (sound_start) |st| {
        const end = if (quiet) quiet_from else pcm.len;
        if (end > st) try out.append(gpa, .{ .start = @as(f64, @floatFromInt(st)) / r, .end = @as(f64, @floatFromInt(end)) / r });
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;
const testdata = @import("testdata.zig");
const demo = @import("demo.zig");
const messages = @import("messages.zig");

test "speechIntervals" {
    const gpa = testing.allocator;
    // 10 Hz "rate": 1 s silence, 0.5 s sound, 0.2 s quiet (too short), 0.3 s sound, 1 s silence.
    var pcm: [30]f32 = @splat(0);
    for (10..15) |i| pcm[i] = 0.5;
    for (17..20) |i| pcm[i] = -0.5;
    const iv = try speechIntervals(gpa, &pcm, 10, -45, 0.4);
    defer gpa.free(iv);
    try testing.expectEqual(@as(usize, 1), iv.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), iv[0].start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), iv[0].end, 1e-9);
    // All silent: nothing.
    const none = try speechIntervals(gpa, pcm[0..9], 10, -45, 0.4);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

fn fakePlayer(gpa: std.mem.Allocator, name: []const u8) !players.Player {
    return .{ .name = try gpa.dupe(u8, name), .steamid = try gpa.dupe(u8, ""), .joined = 0 };
}

test "addPlayer: overlap pushes back, gaps stay silent, lost packets reported" {
    const gpa = testing.allocator;
    // Placement is only visible with real audio: encode a tone.
    var enc: opus.Encoder = try .init(sample_rate, 48000);
    defer enc.deinit();
    var tone: [steamvoice.frame_samples]f32 = undefined;
    for (&tone, 0..) |*x, i| x.* = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
    var frame_buf: [256]u8 = undefined;
    // Warm up so the frame decodes to clearly non-silent audio.
    _ = try enc.encode(&tone, &frame_buf);
    const flen = try enc.encode(&tone, &frame_buf);

    var pkts: [3][512]u8 = undefined;
    var pl = try fakePlayer(gpa, "p");
    defer {
        gpa.free(pl.name);
        gpa.free(pl.steamid);
        pl.packets.deinit(gpa);
    }
    // Two packets in the same frame at t=1 (seq 0, 1), one at t=2 (seq 2),
    // and garbage at t=3.
    for (0..3) |k| {
        const b = &pkts[k];
        std.mem.writeInt(u64, b[0..8], 76561199487820327, .little);
        b[8] = 0x06;
        std.mem.writeInt(u16, b[9..11], @intCast(4 + flen), .little);
        std.mem.writeInt(u16, b[11..13], @intCast(flen), .little);
        std.mem.writeInt(u16, b[13..15], @intCast(k), .little);
        @memcpy(b[15..][0..flen], frame_buf[0..flen]);
        const n = 15 + flen;
        std.mem.writeInt(u32, b[n..][0..4], std.hash.Crc32.hash(b[0..n]), .little);
        try pl.packets.append(gpa, .{ .time = if (k < 2) 1 else 2, .data = b[0 .. n + 4] });
    }
    try pl.packets.append(gpa, .{ .time = 3, .data = "junk" });

    const pcm = try gpa.alloc(f32, length(3));
    defer gpa.free(pcm);
    @memset(pcm, 0);
    var report: Report = .{};
    defer report.deinit(gpa);
    try addPlayer(gpa, pcm, &pl, &report);

    const iv = try speechIntervals(gpa, pcm, sample_rate, -45, 0.4);
    defer gpa.free(iv);
    // Burst at 1.00..1.04 (second packet pushed after the first), then 2.00..2.02.
    try testing.expectEqual(@as(usize, 2), iv.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), iv[0].start, 0.005);
    try testing.expectApproxEqAbs(@as(f64, 1.04), iv[0].end, 0.005);
    try testing.expectApproxEqAbs(@as(f64, 2.0), iv[1].start, 0.005);
    try testing.expectEqual(@as(usize, 1), report.lost.items.len);
    try testing.expectEqual(@as(f32, 3), report.lost.items[0].time);
    try testing.expectEqual(error.NotSteamVoice, report.lost.items[0].err);
}

test "test demos: speech lands where the Rust tool put it (within 20 ms)" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "one-player", "rejoin-team-switch" }) |base| {
        const data = try testdata.readFixture(gpa, base, ".dem");
        defer gpa.free(data);
        var ps: players.Players = .init(gpa);
        defer ps.deinit();
        const d: demo.Demo = try .open(data);
        var w: messages.DemoMessages = .init(gpa, d);
        defer w.deinit();
        while (try w.next()) |fm| try ps.add(fm.frame.time, fm.message);

        const sp = try ps.speakers(gpa, .team);
        defer gpa.free(sp);
        const ts = try players.tracks(gpa, sp, .player);
        defer gpa.free(ts);
        defer players.freeTracks(gpa, ts);
        try testing.expectEqual(@as(usize, 1), ts.len);

        var report: Report = .{};
        defer report.deinit(gpa);
        const pcm = try renderTrack(gpa, ts[0], length(w.max_time), &report);
        defer gpa.free(pcm);
        try testing.expectEqual(@as(usize, 0), report.lost.items.len);
        try testing.expectEqual(@as(u32, 0), report.bad_crc);

        const got = try speechIntervals(gpa, pcm, sample_rate, -45, 0.4);
        defer gpa.free(got);
        const tsv = try testdata.readFixture(gpa, base, ".speech.tsv");
        defer gpa.free(tsv);
        var rows: testdata.TsvIterator = .init(tsv);
        _ = try rows.next(); // header
        var i: usize = 0;
        while (try rows.next()) |row| : (i += 1) {
            const start = try std.fmt.parseFloat(f64, row[0]);
            const end = try std.fmt.parseFloat(f64, row[1]);
            if (i >= got.len) return error.TestMissingInterval;
            if (@abs(got[i].start - start) > 0.02 or @abs(got[i].end - end) > 0.02)
                std.debug.print("{s} interval {d}: want {d:.3}..{d:.3}, got {d:.3}..{d:.3}\n", .{ base, i, start, end, got[i].start, got[i].end });
            try testing.expectApproxEqAbs(start, got[i].start, 0.02);
            try testing.expectApproxEqAbs(end, got[i].end, 0.02);
        }
        try testing.expectEqual(i, got.len);
    }
}
