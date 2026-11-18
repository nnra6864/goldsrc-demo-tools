//! Players: who is in which slot, their identity across rejoins and renames,
//! their starting team, and their voice packets (DESIGN.md "Behaviour").
//! Consumes parsed messages; knows nothing about audio.

const std = @import("std");
const messages = @import("messages.zig");
const usermsg = @import("usermsg.zig");

/// A starting team. Order matters: `--order team` sorts T, CT, then the rest.
pub const Team = enum {
    t,
    ct,
    other,

    pub fn label(t: Team) []const u8 {
        return switch (t) {
            .t => "T",
            .ct => "CT",
            .other => "Other",
        };
    }

    /// T or CT from a `TeamInfo` team name (any case); null for the rest
    /// (`UNASSIGNED`, `SPECTATOR`, ...).
    pub fn fromName(name: []const u8) ?Team {
        if (std.ascii.eqlIgnoreCase(name, "TERRORIST")) return .t;
        if (std.ascii.eqlIgnoreCase(name, "CT")) return .ct;
        return null;
    }
};

/// One `svc_voicedata` payload and when it arrived.
pub const Packet = struct {
    /// Demo time of the frame.
    time: f32,
    /// Borrowed from the demo bytes.
    data: []const u8,
};

pub const Player = struct {
    /// Latest name. Owned.
    name: []u8,
    /// SteamID64 in decimal, empty if none. Owned.
    steamid: []u8,
    /// Demo time of the first userinfo (or voice, for a placeholder).
    joined: f32,
    /// First T or CT team; `.other` if never on one.
    start_team: Team = .other,
    /// Voice from a slot no userinfo ever named (`slot N`).
    placeholder: bool = false,
    packets: std.ArrayList(Packet) = .empty,
};

/// Value of `key` in a userinfo string `\key\value\key\value...`; the last
/// one if the key repeats. Null if absent.
pub fn infoValue(info: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, std.mem.trimStart(u8, info, "\\"), '\\');
    var found: ?[]const u8 = null;
    while (it.next()) |k| {
        const v = it.next() orelse break;
        if (std.mem.eql(u8, k, key)) found = v;
    }
    return found;
}

/// Everyone seen in the demo, fed message by message.
pub const Players = struct {
    gpa: std.mem.Allocator,
    /// In order of first appearance (join order).
    list: std.ArrayList(Player) = .empty,
    /// Identity (SteamID, or `name:<name>`) -> index in `list`. Keys owned.
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    /// Slot -> index in `list` of whoever is in it now.
    slots: [256]?usize = @splat(null),
    /// Codec from the last `svc_voiceinit`, if any. Owned.
    codec: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator) Players {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Players) void {
        for (p.list.items) |*pl| {
            p.gpa.free(pl.name);
            p.gpa.free(pl.steamid);
            pl.packets.deinit(p.gpa);
        }
        p.list.deinit(p.gpa);
        var keys = p.ids.keyIterator();
        while (keys.next()) |k| p.gpa.free(k.*);
        p.ids.deinit(p.gpa);
        if (p.codec) |c| p.gpa.free(c);
    }

    /// Updates players from one message at demo time `time`.
    pub fn add(p: *Players, time: f32, msg: messages.Message) !void {
        switch (msg) {
            .update_userinfo => |u| try p.userInfo(time, u),
            .voice_data => |v| {
                if (v.data.len == 0) return;
                const i = p.slots[v.slot] orelse try p.placeholder(time, v.slot);
                try p.list.items[i].packets.append(p.gpa, .{ .time = time, .data = v.data });
            },
            .voice_init => |v| {
                const codec = try p.gpa.dupe(u8, v.codec);
                if (p.codec) |old| p.gpa.free(old);
                p.codec = codec;
            },
            .user => |u| if (std.mem.eql(u8, u.name, "TeamInfo")) {
                const ti = usermsg.TeamInfo.parse(u.data) catch return;
                if (ti.entity == 0) return;
                const i = p.slots[ti.entity - 1] orelse return;
                const team = Team.fromName(ti.team) orelse return;
                const pl = &p.list.items[i];
                if (pl.start_team == .other) pl.start_team = team;
            },
            .engine => {},
        }
    }

    fn userInfo(p: *Players, time: f32, u: messages.UserInfo) !void {
        const name = infoValue(u.info, "name") orelse "";
        if (name.len == 0) {
            // Empty userinfo: the slot was freed.
            p.slots[u.slot] = null;
            return;
        }
        if (infoValue(u.info, "*hltv") != null) return;
        const sid = infoValue(u.info, "*sid") orelse "";
        const has_sid = sid.len != 0 and !std.mem.eql(u8, sid, "0");

        var id_buf: [300]u8 = undefined;
        const id = if (has_sid) sid else std.fmt.bufPrint(&id_buf, "name:{s}", .{name}) catch name;
        const gop = try p.ids.getOrPut(p.gpa, id);
        if (!gop.found_existing) {
            errdefer p.ids.removeByPtr(gop.key_ptr);
            const key = try p.gpa.dupe(u8, id);
            errdefer p.gpa.free(key);
            try p.list.ensureUnusedCapacity(p.gpa, 1);
            const owned_name = try p.gpa.dupe(u8, name);
            errdefer p.gpa.free(owned_name);
            const owned_sid = try p.gpa.dupe(u8, if (has_sid) sid else "");
            p.list.appendAssumeCapacity(.{ .name = owned_name, .steamid = owned_sid, .joined = time });
            gop.key_ptr.* = key;
            gop.value_ptr.* = p.list.items.len - 1;
        } else {
            // Latest name wins, renames included.
            const pl = &p.list.items[gop.value_ptr.*];
            if (!std.mem.eql(u8, pl.name, name)) {
                const new_name = try p.gpa.dupe(u8, name);
                p.gpa.free(pl.name);
                pl.name = new_name;
            }
        }
        p.slots[u.slot] = gop.value_ptr.*;
    }

    fn placeholder(p: *Players, time: f32, slot: u8) !usize {
        const name = try std.fmt.allocPrint(p.gpa, "slot {d}", .{@as(u16, slot) + 1});
        errdefer p.gpa.free(name);
        const sid = try p.gpa.dupe(u8, "");
        errdefer p.gpa.free(sid);
        try p.list.append(p.gpa, .{ .name = name, .steamid = sid, .joined = time, .placeholder = true });
        const i = p.list.items.len - 1;
        p.slots[slot] = i;
        return i;
    }

    /// Players who spoke, in `order`. Caller frees the slice.
    pub fn speakers(p: *const Players, gpa: std.mem.Allocator, order: Order) ![]*const Player {
        var out: std.ArrayList(*const Player) = .empty;
        errdefer out.deinit(gpa);
        for (p.list.items) |*pl| {
            if (pl.packets.items.len != 0) try out.append(gpa, pl);
        }
        if (order == .team) {
            // Stable: join order within a team.
            std.mem.sort(*const Player, out.items, {}, struct {
                fn lessThan(_: void, a: *const Player, b: *const Player) bool {
                    return @backingInt(a.start_team) < @backingInt(b.start_team);
                }
            }.lessThan);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// `--order`.
pub const Order = enum { join, team };

/// `--tracks`.
pub const TrackMode = enum { player, team, mix };

/// One output track and the players mixed into it.
pub const Track = struct {
    /// Player name, team label, or `All`. Borrowed.
    title: []const u8,
    /// The player's SteamID for player tracks, empty otherwise. Borrowed.
    steamid: []const u8,
    /// Owned slice (free with `freeTracks`).
    players: []*const Player,
};

/// Groups speakers (already in output order) into tracks. Tracks come in the
/// order of their first player.
pub fn tracks(gpa: std.mem.Allocator, speakers: []const *const Player, mode: TrackMode) ![]Track {
    var out: std.ArrayList(Track) = .empty;
    errdefer freeTracks(gpa, out.items);
    defer out.deinit(gpa);
    for (speakers) |pl| {
        const title, const sid = switch (mode) {
            .player => .{ pl.name, pl.steamid },
            .team => .{ pl.start_team.label(), "" },
            .mix => .{ "All", "" },
        };
        if (mode != .player) {
            if (findTrack(out.items, title)) |t| {
                const grown = try gpa.realloc(t.players, t.players.len + 1);
                grown[grown.len - 1] = pl;
                t.players = grown;
                continue;
            }
        }
        const members = try gpa.alloc(*const Player, 1);
        members[0] = pl;
        out.append(gpa, .{ .title = title, .steamid = sid, .players = members }) catch |err| {
            gpa.free(members);
            return err;
        };
    }
    return out.toOwnedSlice(gpa);
}

fn findTrack(list: []Track, title: []const u8) ?*Track {
    for (list) |*t| {
        if (std.mem.eql(u8, t.title, title)) return t;
    }
    return null;
}

pub fn freeTracks(gpa: std.mem.Allocator, list: []Track) void {
    for (list) |t| gpa.free(t.players);
}

const testing = std.testing;
const testdata = @import("testdata.zig");
const demo = @import("demo.zig");

test "infoValue" {
    const info = "\\name\\nnra\\*sid\\76561199487820327\\model\\urban\\name\\other";
    try testing.expectEqualStrings("other", infoValue(info, "name").?);
    try testing.expectEqualStrings("76561199487820327", infoValue(info, "*sid").?);
    try testing.expectEqual(@as(?[]const u8, null), infoValue(info, "*hltv"));
    try testing.expectEqualStrings("", infoValue("\\*hltv\\\\name\\x", "*hltv").?);
    try testing.expectEqual(@as(?[]const u8, null), infoValue("", "name"));
    try testing.expectEqual(@as(?[]const u8, null), infoValue("\\name", "name"));
}

fn userinfo(p: *Players, time: f32, slot: u8, info: []const u8) !void {
    try p.add(time, .{ .update_userinfo = .{ .slot = slot, .user_id = 1, .info = info } });
}

fn voice(p: *Players, time: f32, slot: u8, data: []const u8) !void {
    try p.add(time, .{ .voice_data = .{ .slot = slot, .data = data } });
}

fn teamInfo(p: *Players, time: f32, entity: u8, team: []const u8) !void {
    var buf: [32]u8 = undefined;
    buf[0] = entity;
    @memcpy(buf[1..][0..team.len], team);
    buf[1 + team.len] = 0;
    try p.add(time, .{ .user = .{ .id = 70, .name = "TeamInfo", .data = buf[0 .. team.len + 2] } });
}

test "rejoin in another slot continues the same player; latest name wins" {
    var p: Players = .init(testing.allocator);
    defer p.deinit();
    try userinfo(&p, 1, 0, "\\name\\HLTV\\*hltv\\1\\*sid\\90071996842377216");
    try userinfo(&p, 2, 1, "\\name\\nnra\\*sid\\765");
    try teamInfo(&p, 2, 2, "UNASSIGNED");
    try teamInfo(&p, 2.5, 2, "TERRORIST");
    try voice(&p, 3, 1, "a");
    try userinfo(&p, 4, 1, ""); // disconnect
    try voice(&p, 4.5, 1, "lost?"); // nobody in slot 1 now: placeholder
    try userinfo(&p, 5, 3, "\\name\\nnra2\\*sid\\765");
    try teamInfo(&p, 5, 4, "CT");
    try voice(&p, 6, 3, "b");
    try voice(&p, 6.5, 0, "hltv slot"); // HLTV never got a player: placeholder

    try testing.expectEqual(@as(usize, 3), p.list.items.len);
    const pl = p.list.items[0];
    try testing.expectEqualStrings("nnra2", pl.name);
    try testing.expectEqualStrings("765", pl.steamid);
    try testing.expectEqual(Team.t, pl.start_team);
    try testing.expectEqual(@as(f32, 2), pl.joined);
    try testing.expectEqual(@as(usize, 2), pl.packets.items.len);
    try testing.expectEqualStrings("a", pl.packets.items[0].data);
    try testing.expectEqual(@as(f32, 6), pl.packets.items[1].time);

    const slot2 = p.list.items[1];
    try testing.expectEqualStrings("slot 2", slot2.name);
    try testing.expect(slot2.placeholder);
    try testing.expectEqual(@as(f32, 4.5), slot2.joined);
    try testing.expectEqualStrings("slot 1", p.list.items[2].name);
}

test "no SteamID falls back to the name; SteamID 0 counts as none" {
    var p: Players = .init(testing.allocator);
    defer p.deinit();
    try userinfo(&p, 1, 0, "\\name\\bot");
    try userinfo(&p, 2, 1, "\\name\\bot\\*sid\\0");
    try userinfo(&p, 3, 2, "\\name\\other");
    try testing.expectEqual(@as(usize, 2), p.list.items.len);
    try testing.expectEqualStrings("", p.list.items[0].steamid);
    try testing.expectEqual(p.slots[0], p.slots[1]);
    // A name with SteamID is a different player from the same name without.
    try userinfo(&p, 4, 3, "\\name\\bot\\*sid\\123");
    try testing.expectEqual(@as(usize, 3), p.list.items.len);
}

test "starting team: first T or CT only; team entities and empty slots ignored" {
    var p: Players = .init(testing.allocator);
    defer p.deinit();
    try teamInfo(&p, 0, 34, "TERRORIST"); // team entity
    try teamInfo(&p, 0, 0, "CT"); // entity 0
    try userinfo(&p, 1, 0, "\\name\\a\\*sid\\1");
    try teamInfo(&p, 1, 1, "SPECTATOR");
    try testing.expectEqual(Team.other, p.list.items[0].start_team);
    try teamInfo(&p, 2, 1, "ct");
    try teamInfo(&p, 3, 1, "TERRORIST"); // halftime switch: ignored
    try testing.expectEqual(Team.ct, p.list.items[0].start_team);
    // Malformed TeamInfo is ignored.
    try p.add(4, .{ .user = .{ .id = 70, .name = "TeamInfo", .data = "" } });
}

test "voiceinit codec, empty voice ignored" {
    var p: Players = .init(testing.allocator);
    defer p.deinit();
    try p.add(0, .{ .voice_init = .{ .codec = "voice_speex", .quality = 5 } });
    try p.add(0, .{ .voice_init = .{ .codec = "", .quality = 5 } });
    try testing.expectEqualStrings("", p.codec.?);
    try voice(&p, 1, 0, "");
    try testing.expectEqual(@as(usize, 0), p.list.items.len);
}

/// Speakers: a (T, joined 1st), b (CT), c (never on a team), d (T).
fn fourSpeakers(p: *Players) !void {
    for ([_][]const u8{ "\\name\\a\\*sid\\1", "\\name\\b\\*sid\\2", "\\name\\c\\*sid\\3", "\\name\\d\\*sid\\4", "\\name\\silent\\*sid\\5" }, 0..) |info, i| {
        try userinfo(p, @floatFromInt(i), @intCast(i), info);
    }
    try teamInfo(p, 5, 1, "TERRORIST");
    try teamInfo(p, 5, 2, "CT");
    try teamInfo(p, 5, 4, "TERRORIST");
    try teamInfo(p, 5, 5, "CT");
    for (0..4) |i| try voice(p, 6, @intCast(i), "x");
}

fn names(list: []const *const Player, buf: []u8) []const u8 {
    var n: usize = 0;
    for (list) |pl| {
        @memcpy(buf[n..][0..pl.name.len], pl.name);
        n += pl.name.len;
    }
    return buf[0..n];
}

test "order: join, and team (T, CT, rest; join order within a team)" {
    const gpa = testing.allocator;
    var p: Players = .init(gpa);
    defer p.deinit();
    try fourSpeakers(&p);
    var buf: [16]u8 = undefined;
    const join = try p.speakers(gpa, .join);
    defer gpa.free(join);
    try testing.expectEqualStrings("abcd", names(join, &buf));
    const team = try p.speakers(gpa, .team);
    defer gpa.free(team);
    try testing.expectEqualStrings("adbc", names(team, &buf));
}

test "tracks: player, team, mix" {
    const gpa = testing.allocator;
    var p: Players = .init(gpa);
    defer p.deinit();
    try fourSpeakers(&p);
    const sp = try p.speakers(gpa, .team);
    defer gpa.free(sp);

    const per_player = try tracks(gpa, sp, .player);
    defer gpa.free(per_player);
    defer freeTracks(gpa, per_player);
    try testing.expectEqual(@as(usize, 4), per_player.len);
    try testing.expectEqualStrings("a", per_player[0].title);
    try testing.expectEqualStrings("1", per_player[0].steamid);

    const per_team = try tracks(gpa, sp, .team);
    defer gpa.free(per_team);
    defer freeTracks(gpa, per_team);
    try testing.expectEqual(@as(usize, 3), per_team.len);
    try testing.expectEqualStrings("T", per_team[0].title);
    try testing.expectEqual(@as(usize, 2), per_team[0].players.len);
    try testing.expectEqualStrings("d", per_team[0].players[1].name);
    try testing.expectEqualStrings("CT", per_team[1].title);
    try testing.expectEqualStrings("Other", per_team[2].title);
    try testing.expectEqualStrings("", per_team[0].steamid);

    const mix = try tracks(gpa, sp, .mix);
    defer gpa.free(mix);
    defer freeTracks(gpa, mix);
    try testing.expectEqual(@as(usize, 1), mix.len);
    try testing.expectEqualStrings("All", mix[0].title);
    try testing.expectEqual(@as(usize, 4), mix[0].players.len);
}

/// Reads a test demo into `p`.
fn readDemo(p: *Players, data: []const u8) !void {
    const d: demo.Demo = try .open(data);
    var w: messages.DemoMessages = .init(testing.allocator, d);
    defer w.deinit();
    while (try w.next()) |fm| try p.add(fm.frame.time, fm.message);
    try testing.expectEqual(@as(usize, 0), w.failures.items.len);
}

test "test demos: speakers" {
    const gpa = testing.allocator;
    const cases = [_]struct { base: []const u8, team: ?Team, packets: usize }{
        .{ .base = "rejoin-team-switch", .team = .t, .packets = 379 },
        .{ .base = "one-player", .team = .ct, .packets = 47 },
        .{ .base = "truncated-no-directory", .team = null, .packets = 0 },
    };
    for (cases) |c| {
        const data = try testdata.readFixture(gpa, c.base, ".dem");
        defer gpa.free(data);
        var p: Players = .init(gpa);
        defer p.deinit();
        try readDemo(&p, data);
        const sp = try p.speakers(gpa, .join);
        defer gpa.free(sp);
        if (c.team) |team| {
            try testing.expectEqual(@as(usize, 1), sp.len);
            try testing.expectEqualStrings("nnra", sp[0].name);
            try testing.expectEqualStrings("76561199487820327", sp[0].steamid);
            try testing.expectEqual(team, sp[0].start_team);
            try testing.expectEqual(c.packets, sp[0].packets.items.len);
        } else {
            try testing.expectEqual(@as(usize, 0), sp.len);
        }
        // No svc_voiceinit in these demos.
        try testing.expectEqual(@as(?[]u8, null), p.codec);
    }
}
