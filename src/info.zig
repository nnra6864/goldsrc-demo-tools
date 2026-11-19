//! `info` output: what a demo holds, one `key value` per line, for scripts
//! (DESIGN.md "CLI"). The server uses `players` and `unidentified` to delete
//! demos nobody joined.

const std = @import("std");
const demo = @import("demo.zig");
const messages = @import("messages.zig");
const players = @import("players.zig");

/// Counts of who joined. HLTV is never counted (`players` skips it).
pub const Joined = struct {
    /// Joined with a SteamID.
    players: usize = 0,
    /// Joined without one (bots, non-Steam clients), or voice from a slot no
    /// userinfo named.
    unidentified: usize = 0,

    pub fn count(ps: *const players.Players) Joined {
        var j: Joined = .{};
        for (ps.list.items) |pl| {
            if (pl.steamid.len != 0) j.players += 1 else j.unidentified += 1;
        }
        return j;
    }
};

/// Writes the info lines. `walk` must have been run to the end.
pub fn write(w: *std.Io.Writer, d: demo.Demo, walk: *const messages.DemoMessages, ps: *const players.Players) !void {
    try w.print("map {s}\n", .{d.header.map_name});
    try w.writeAll("duration ");
    try demo.formatFixed(w, walk.max_time, 3);
    try w.writeAll("\n");
    try w.print("directory {s}\n", .{if (d.directory_problem) |p| @tagName(p) else "ok"});
    const cut = if (walk.frames.problem) |p| p.kind == .truncated else false;
    try w.print("end {s}\n", .{if (cut) "cut-off" else "complete"});
    const j: Joined = .count(ps);
    try w.print("players {d}\nunidentified {d}\n", .{ j.players, j.unidentified });
    for (ps.list.items) |pl| {
        try w.print("player {s} {s}\n", .{ if (pl.steamid.len != 0) pl.steamid else "-", pl.name });
    }
}

const testing = std.testing;

test "Joined.count: SteamID or not; HLTV never counted" {
    var ps: players.Players = .init(testing.allocator);
    defer ps.deinit();
    const ui = struct {
        fn f(p: *players.Players, slot: u8, info: []const u8) !void {
            try p.add(0, .{ .update_userinfo = .{ .slot = slot, .user_id = slot, .info = info } });
        }
    }.f;
    try ui(&ps, 0, "\\name\\HLTV\\*hltv\\1\\*sid\\90071996842377216");
    try testing.expectEqual(Joined{}, Joined.count(&ps));
    try ui(&ps, 1, "\\name\\bot");
    try ui(&ps, 2, "\\name\\nnra\\*sid\\76561199487820327");
    try testing.expectEqual(Joined{ .players = 1, .unidentified = 1 }, Joined.count(&ps));
}
