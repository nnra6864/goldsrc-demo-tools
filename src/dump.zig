//! `--dump`: who spoke and their first packets, in the Rust tool's format.

const std = @import("std");
const players = @import("players.zig");
const steamvoice = @import("steamvoice.zig");
const demo = @import("demo.zig");

/// `t` as Rust's `{:.N}` would print it (see `demo.formatFixed`).
fn fixed(buf: []u8, t: f32, comptime decimals: u3) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    demo.formatFixed(&w, t, decimals) catch return "?";
    return w.buffered();
}

/// Writes the dump: codec and duration, then each speaker (join order) with
/// up to 3 packets.
pub fn write(w: *std.Io.Writer, ps: *const players.Players, duration: f32) !void {
    if (ps.codec) |codec| {
        var b: [1][32]u8 = undefined;
        try w.print("codec: \"{s}\", duration {s}s\n", .{ codec, fixed(&b[0], duration, 1) });
    } else {
        var b: [1][32]u8 = undefined;
        try w.print("codec: \"(no svc_voiceinit)\", duration {s}s\n", .{fixed(&b[0], duration, 1)});
    }
    for (ps.list.items) |*pl| {
        const packets = pl.packets.items;
        if (packets.len == 0) continue;
        var bytes: usize = 0;
        for (packets) |p| bytes += p.data.len;
        var b: [3][32]u8 = undefined;
        try w.print("{s:<5} {s:<24} {s:<20} joined {s:>7}s, {d:>5} packets, {d} bytes, {s}s..{s}s\n", .{
            pl.start_team.label(),
            pl.name,
            pl.steamid,
            fixed(&b[0], pl.joined, 1),
            packets.len,
            bytes,
            fixed(&b[1], packets[0].time, 1),
            fixed(&b[2], packets[packets.len - 1].time, 1),
        });
        for (packets[0..@min(3, packets.len)]) |p| {
            var tb: [32]u8 = undefined;
            try w.print("    {s:>8}s {d:>4}B {x} ", .{ fixed(&tb, p.time, 3), p.data.len, p.data[0..@min(32, p.data.len)] });
            try steamvoice.describe(w, p.data);
            try w.writeByte('\n');
        }
    }
}

const testing = std.testing;

test "dump format" {
    const gpa = testing.allocator;
    var ps: players.Players = .init(gpa);
    defer ps.deinit();
    try ps.add(1.25, .{ .update_userinfo = .{ .slot = 0, .user_id = 1, .info = "\\name\\nnra\\*sid\\765" } });
    try ps.add(2, .{ .voice_data = .{ .slot = 0, .data = "ab" } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&out.writer, &ps, 85.62);
    try testing.expectEqualStrings(
        \\codec: "(no svc_voiceinit)", duration 85.6s
        \\Other nnra                     765                  joined     1.2s,     1 packets, 2 bytes, 2.0s..2.0s
        \\       2.000s    2B 6162 (not a Steam voice packet: NotSteamVoice)
        \\
    , out.written());
}
