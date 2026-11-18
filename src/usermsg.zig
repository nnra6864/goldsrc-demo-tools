//! User messages: mod-defined messages with ids 64..255, registered by
//! `svc_newusermsg` (ReHLTV `Server::ParseNewUserMsg`, `ParseUserMessage`).

const std = @import("std");
const bits = @import("bits.zig");

/// First user message id (`svc_startofusermessages`).
pub const first_id = 64;
/// Largest user message payload ReHLTV accepts (`MAX_USER_MSG_DATA`).
pub const max_data = 192;
/// Size byte meaning "variable": a length byte follows the id.
pub const variable_size = 255;
/// Bytes of the name in `svc_newusermsg`.
pub const name_size = 16;

/// A registered user message.
pub const UserMsg = struct {
    /// Payload size, or null for variable size (length byte first).
    size: ?u8,
    name_buf: [name_size]u8,
    name_len: u8,

    pub fn name(m: *const UserMsg) []const u8 {
        return m.name_buf[0..m.name_len];
    }
};

/// The user messages registered so far, by id.
pub const Table = struct {
    msgs: [256]?UserMsg = @splat(null),

    /// Registers (or re-registers) a message from an `svc_newusermsg` body:
    /// `size_byte` 255 means variable size; `name` is the 16-byte field.
    pub fn register(t: *Table, id: u8, size_byte: u8, name: *const [name_size]u8) void {
        const len = std.mem.indexOfScalar(u8, name, 0) orelse name_size;
        var m: UserMsg = .{
            .size = if (size_byte == variable_size) null else size_byte,
            .name_buf = name.*,
            .name_len = @intCast(len),
        };
        @memset(m.name_buf[len..], 0);
        t.msgs[id] = m;
    }

    pub fn get(t: *const Table, id: u8) ?*const UserMsg {
        if (t.msgs[id]) |*m| return m;
        return null;
    }
};

pub const ReadError = bits.BitReader.Error || error{
    /// The id was never registered by `svc_newusermsg`: its size is unknown.
    UnknownUserMessage,
    /// The payload is larger than `max_data`.
    UserMessageTooLarge,
};

/// Reads a user message's payload (after the id): fixed size, or a length
/// byte then that many bytes. Returns the payload, borrowed.
pub fn readPayload(table: *const Table, id: u8, r: *bits.BitReader) ReadError!struct { msg: *const UserMsg, data: []const u8 } {
    const msg = table.get(id) orelse return error.UnknownUserMessage;
    const size: usize = msg.size orelse try r.readByte();
    if (size > max_data) return error.UserMessageTooLarge;
    return .{ .msg = msg, .data = try r.bytes(size) };
}

/// A `TeamInfo` message (CS and others): entity index (slot + 1) and team
/// name (`TERRORIST`, `CT`, `UNASSIGNED`, `SPECTATOR`).
pub const TeamInfo = struct {
    entity: u8,
    /// Borrowed from the payload.
    team: []const u8,

    /// Parses a TeamInfo payload. The team name may lack its NUL at the very
    /// end of the payload; anything after a NUL is ignored.
    pub fn parse(data: []const u8) error{TruncatedTeamInfo}!TeamInfo {
        if (data.len < 1) return error.TruncatedTeamInfo;
        const rest = data[1..];
        const len = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return .{ .entity = data[0], .team = rest[0..len] };
    }
};

const testing = std.testing;

fn name16(s: []const u8) [name_size]u8 {
    var n: [name_size]u8 = @splat(0);
    @memcpy(n[0..s.len], s);
    return n;
}

test "Table: fixed and variable sizes" {
    var t: Table = .{};
    t.register(70, 2, &name16("Health"));
    t.register(71, 255, &name16("TeamInfo"));
    // Garbage after the NUL is dropped.
    var odd = name16("Money");
    odd[10] = 'x';
    t.register(72, 5, &odd);
    try testing.expectEqualStrings("Health", t.get(70).?.name());
    try testing.expectEqual(@as(?u8, 2), t.get(70).?.size);
    try testing.expectEqual(@as(?u8, null), t.get(71).?.size);
    try testing.expectEqualStrings("Money", t.get(72).?.name());
    try testing.expectEqual(@as(?*const UserMsg, null), t.get(73));
    // A full 16-char name has no NUL.
    t.register(73, 0, &name16("ABCDEFGHIJKLMNOP"));
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", t.get(73).?.name());
}

test "readPayload" {
    var t: Table = .{};
    t.register(70, 2, &name16("Health"));
    t.register(71, 255, &name16("TeamInfo"));
    t.register(72, 200, &name16("Huge"));
    var r: bits.BitReader = .init(&.{ 0x64, 0x00, 0x04, 1, 'C', 'T', 0, 0xee });
    const a = try readPayload(&t, 70, &r);
    try testing.expectEqualStrings("Health", a.msg.name());
    try testing.expectEqualSlices(u8, &.{ 0x64, 0x00 }, a.data);
    const b = try readPayload(&t, 71, &r);
    try testing.expectEqualSlices(u8, &.{ 1, 'C', 'T', 0 }, b.data);
    try testing.expectEqual(@as(u8, 0xee), try r.readByte());

    try testing.expectError(error.UnknownUserMessage, readPayload(&t, 99, &r));
    try testing.expectError(error.UserMessageTooLarge, readPayload(&t, 72, &r));
    var short: bits.BitReader = .init(&.{ 5, 1 });
    try testing.expectError(error.EndOfBuffer, readPayload(&t, 71, &short));
}

test "TeamInfo.parse" {
    const ti = try TeamInfo.parse(&.{ 1, 'T', 'E', 'R', 'R', 'O', 'R', 'I', 'S', 'T', 0 });
    try testing.expectEqual(@as(u8, 1), ti.entity);
    try testing.expectEqualStrings("TERRORIST", ti.team);
    const no_nul = try TeamInfo.parse(&.{ 2, 'C', 'T' });
    try testing.expectEqualStrings("CT", no_nul.team);
    try testing.expectError(error.TruncatedTeamInfo, TeamInfo.parse(&.{}));
}
