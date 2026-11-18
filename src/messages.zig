//! Net messages (ReHLTV `Core/src/Server.cpp`, doc/FORMAT.md).
//!
//! A network frame's data is a sequence of messages with no lengths: an id
//! byte, then the message. Every message must be parsed to find the next.
//! Knows the protocol, but nothing about players or audio.

const std = @import("std");
const bits = @import("bits.zig");
const delta = @import("delta.zig");
const usermsg = @import("usermsg.zig");
const demo = @import("demo.zig");
const BitReader = bits.BitReader;

/// Engine message ids, protocol 48 (`svc_commands_e`). 64 and up are user
/// messages.
pub const Id = enum(u8) {
    bad = 0,
    nop = 1,
    disconnect = 2,
    event = 3,
    version = 4,
    setview = 5,
    sound = 6,
    time = 7,
    print = 8,
    stufftext = 9,
    setangle = 10,
    serverinfo = 11,
    lightstyle = 12,
    updateuserinfo = 13,
    deltadescription = 14,
    clientdata = 15,
    stopsound = 16,
    pings = 17,
    particle = 18,
    damage = 19,
    spawnstatic = 20,
    event_reliable = 21,
    spawnbaseline = 22,
    temp_entity = 23,
    setpause = 24,
    signonnum = 25,
    centerprint = 26,
    killedmonster = 27,
    foundsecret = 28,
    spawnstaticsound = 29,
    intermission = 30,
    finale = 31,
    cdtrack = 32,
    restore = 33,
    cutscene = 34,
    weaponanim = 35,
    decalname = 36,
    roomtype = 37,
    addangle = 38,
    newusermsg = 39,
    packetentities = 40,
    deltapacketentities = 41,
    choke = 42,
    resourcelist = 43,
    newmovevars = 44,
    resourcerequest = 45,
    customization = 46,
    crosshairangle = 47,
    soundfade = 48,
    filetxferfailed = 49,
    hltv = 50,
    director = 51,
    voiceinit = 52,
    voicedata = 53,
    sendextrainfo = 54,
    timescale = 55,
    resourcelocation = 56,
    sendcvarvalue = 57,
    sendcvarvalue2 = 58,
    exec = 59,
    _,

    /// `svc_xxx` name for messages, `svc_reserved` for 60..63, `user` above.
    pub fn name(id: Id) []const u8 {
        return switch (id) {
            _ => if (@backingInt(id) >= usermsg.first_id) "user" else "svc_reserved",
            inline else => |t| "svc_" ++ @tagName(t),
        };
    }
};

/// `svc_voicedata`: voice from one client.
pub const VoiceData = struct {
    /// 0-based client slot of the sender.
    slot: u8,
    /// The voice payload (a Steam voice packet), borrowed from the frame.
    data: []const u8,
};

/// `svc_updateuserinfo`.
pub const UserInfo = struct {
    slot: u8,
    user_id: u32,
    /// `\key\value...`, borrowed. Empty means the slot was freed.
    info: []const u8,
};

/// `svc_voiceinit`.
pub const VoiceInit = struct {
    /// Borrowed. Empty for Steam voice.
    codec: []const u8,
    quality: u8,
};

/// A user message (id 64..255).
pub const User = struct {
    id: u8,
    /// Borrowed from the parser's table: valid until the id is re-registered.
    name: []const u8,
    /// Payload, borrowed from the frame.
    data: []const u8,
};

/// One parsed message. The ones we use carry their contents; every other
/// engine message is parsed, skipped and reported by id.
pub const Message = union(enum) {
    voice_data: VoiceData,
    update_userinfo: UserInfo,
    voice_init: VoiceInit,
    user: User,
    engine: Id,
};

pub const Error = delta.Error || usermsg.ReadError || error{
    OutOfMemory,
    /// `svc_bad`, or a reserved engine id (60..63).
    BadMessage,
    /// A bit-level message needs a delta table the demo never sent.
    MissingDeltaTable,
    /// `svc_deltadescription` with an empty table name.
    EmptyTableName,
    /// `svc_temp_entity` of a type with no known size.
    BadTempEntity,
    /// `svc_hltv` with an unknown command.
    BadHltvCommand,
    /// `svc_customization` for a slot outside 0..31.
    BadCustomization,
    /// An entity list doesn't end with its 16-bit zero.
    BadEntityListEnd,
};

/// Delta table names (`Delta::UpdateDescriptions`).
const table_entity = "entity_state_t";
const table_player = "entity_state_player_t";
const table_custom = "custom_entity_state_t";
const table_client = "clientdata_t";
const table_weapon = "weapon_data_t";
const table_event = "event_t";

/// State carried from frame to frame: delta tables, user message ids, and
/// the few server facts that change how messages are read.
pub const Parser = struct {
    gpa: std.mem.Allocator,
    tables: delta.Tables = .{},
    user_msgs: usermsg.Table = .{},
    /// From `svc_serverinfo`: entity indexes 1..max_clients are players
    /// (decoded with `entity_state_player_t`).
    max_clients: u8 = 0,
    /// From `svc_spawnbaseline`: when non-zero, entity headers carry an
    /// instanced-baseline flag.
    instanced_baselines: u8 = 0,
    /// Set by `svc_hltv` HLTV_ACTIVE: `svc_clientdata` then has no body.
    is_hltv: bool = false,

    pub fn init(gpa: std.mem.Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Parser) void {
        p.tables.deinit(p.gpa);
    }

    /// Iterates the messages of one network frame.
    pub fn frame(p: *Parser, data: []const u8) MessageIterator {
        return .{ .parser = p, .r = .init(data) };
    }

    fn table(p: *const Parser, name: []const u8) Error![]const delta.Field {
        return p.tables.get(name) orelse error.MissingDeltaTable;
    }

    fn isPlayerIndex(p: *const Parser, index: u32) bool {
        return index >= 1 and index <= p.max_clients;
    }

    fn entityTable(p: *const Parser, index: u32, custom: bool) Error![]const delta.Field {
        if (custom) return p.table(table_custom);
        return p.table(if (p.isPlayerIndex(index)) table_player else table_entity);
    }
};

/// Where in a frame a message failed, for the report.
pub const Failure = struct {
    err: Error,
    /// Byte offset of the failed message's id in the frame data.
    offset: usize,
    /// Id of the failed message.
    id: u8,
    /// Ids of the messages before it in this frame, oldest first (up to 8).
    previous: [8]u8,
    previous_len: u8,

    pub fn previousIds(f: *const Failure) []const u8 {
        return f.previous[0..f.previous_len];
    }
};

/// Walks the messages of one frame. Stops at the first error: the rest of
/// the frame can't be found without it.
pub const MessageIterator = struct {
    parser: *Parser,
    r: BitReader,
    /// Ids seen so far in this frame (the last 8).
    history: [8]u8 = undefined,
    count: usize = 0,
    /// Set when `next` returned an error.
    failure: ?Failure = null,

    /// The next message, null at the end of the frame, or an error (see
    /// `failure`). Don't call again after an error.
    pub fn next(it: *MessageIterator) Error!?Message {
        std.debug.assert(it.failure == null);
        if (it.r.atEnd()) return null;
        const offset = it.r.byteOffset();
        const id = it.r.readByte() catch |err| {
            it.fail(err, offset, 0);
            return err;
        };
        const msg = it.parse(id) catch |err| {
            it.fail(err, offset, id);
            return err;
        };
        it.history[it.count % it.history.len] = id;
        it.count += 1;
        return msg;
    }

    fn fail(it: *MessageIterator, err: Error, offset: usize, id: u8) void {
        var f: Failure = .{ .err = err, .offset = offset, .id = id, .previous = undefined, .previous_len = 0 };
        const n = @min(it.count, it.history.len);
        for (0..n) |i| f.previous[i] = it.history[(it.count - n + i) % it.history.len];
        f.previous_len = @intCast(n);
        it.failure = f;
    }

    fn parse(it: *MessageIterator, raw_id: u8) Error!Message {
        const p = it.parser;
        const r = &it.r;
        if (raw_id >= usermsg.first_id) {
            const u = try usermsg.readPayload(&p.user_msgs, raw_id, r);
            return .{ .user = .{ .id = raw_id, .name = u.msg.name(), .data = u.data } };
        }
        const id: Id = @fromBackingInt(@intCast(raw_id));
        switch (id) {
            .bad, _ => return error.BadMessage,
            // No payload.
            .nop, .damage, .killedmonster, .foundsecret, .intermission, .choke => {},
            // A string.
            .disconnect, .print, .stufftext, .centerprint, .finale, .cutscene, .filetxferfailed, .resourcelocation, .sendcvarvalue => _ = try r.string(),
            // Fixed sizes.
            .version, .time, .timescale => try r.skipBytes(4),
            .setview, .stopsound, .roomtype, .cdtrack, .weaponanim, .addangle, .crosshairangle => try r.skipBytes(2),
            .setpause, .signonnum => try r.skipBytes(1),
            .soundfade => try r.skipBytes(4),
            .setangle => try r.skipBytes(6),
            .particle => try r.skipBytes(11),
            .spawnstaticsound => try r.skipBytes(14),
            .resourcerequest => try r.skipBytes(8),
            .lightstyle, .decalname => {
                try r.skipBytes(1);
                _ = try r.string();
            },
            .sendextrainfo => {
                _ = try r.string();
                try r.skipBytes(1);
            },
            .sendcvarvalue2 => {
                try r.skipBytes(4);
                _ = try r.string();
            },
            .exec => {
                if (try r.readByte() != 0) try r.skipBytes(1);
            },
            .director => try r.skipBytes(try r.readByte()),
            .restore => {
                _ = try r.string();
                for (0..try r.readByte()) |_| _ = try r.string();
            },
            .newmovevars => {
                try r.skipBytes(16 * 4 + 1 + 8 * 4);
                _ = try r.string();
            },
            .spawnstatic => try skipSpawnStatic(r),
            .serverinfo => try parseServerInfo(p, r),
            .customization => try skipCustomization(r),
            .temp_entity => try skipTempEntity(r),
            .hltv => try parseHltv(p, r),
            .newusermsg => {
                const msg_id = try r.readByte();
                const size = try r.readByte();
                const name = (try r.bytes(usermsg.name_size))[0..usermsg.name_size];
                p.user_msgs.register(msg_id, size, name);
            },
            .updateuserinfo => {
                const slot = try r.readByte();
                const user_id = try r.readLong();
                const info = try r.string();
                try r.skipBytes(16); // CD key hash
                return .{ .update_userinfo = .{ .slot = slot, .user_id = user_id, .info = info } };
            },
            .voiceinit => {
                const codec = try r.string();
                const quality = try r.readByte();
                return .{ .voice_init = .{ .codec = codec, .quality = quality } };
            },
            .voicedata => {
                const slot = try r.readByte();
                const len = try r.readShort();
                return .{ .voice_data = .{ .slot = slot, .data = try r.bytes(len) } };
            },
            // Bit-level messages. Each ends aligned to a byte.
            .deltadescription => try delta.readDescription(p.gpa, r, &p.tables),
            .clientdata => try skipClientData(p, r),
            .event => try skipEvent(p, r),
            .event_reliable => try skipEventReliable(p, r),
            .spawnbaseline => try parseSpawnBaseline(p, r),
            .packetentities => {
                try r.skipBytes(2); // entity count
                try skipEntities(p, r, true);
            },
            .deltapacketentities => {
                try r.skipBytes(2 + 1); // entity count, delta-from sequence
                try skipEntities(p, r, false);
            },
            .sound => try skipSound(r),
            .pings => try skipPings(r),
            .resourcelist => try skipResourceList(r),
        }
        return .{ .engine = id };
    }
};

/// Engine `PF_makestatic_I` (ReHLTV ignores it): model index, sequence,
/// frame, colormap, skin, 3 x (coord, angle), render mode and, if non-zero,
/// render amount, color and fx.
fn skipSpawnStatic(r: *BitReader) Error!void {
    try r.skipBytes(2 + 1 + 1 + 2 + 1 + 3 * (2 + 1));
    if (try r.readByte() != 0) try r.skipBytes(5);
}

/// ReHLTV `ParseServerinfo`. Keeps maxclients.
fn parseServerInfo(p: *Parser, r: *BitReader) Error!void {
    try r.skipBytes(4 + 4 + 4 + 16); // protocol, spawn count, map CRC, client.dll MD5
    p.max_clients = try r.readByte();
    try r.skipBytes(1 + 1); // player number, game type
    for (0..4) |_| _ = try r.string(); // game dir, host name, map, map cycle
    if (try r.readByte() != 0) try r.skipBytes(@as(usize, try r.readByte()) + 16);
}

/// ReHLTV `ParseCustomization`.
fn skipCustomization(r: *BitReader) Error!void {
    if (try r.readByte() >= 32) return error.BadCustomization;
    try r.skipBytes(1); // type
    _ = try r.string();
    try r.skipBytes(2 + 4); // index, download size
    const res_custom = 1 << 2;
    if (try r.readByte() & res_custom != 0) try r.skipBytes(16);
}

/// Payload sizes of temp entities by type (ReHLTV `TE_LENGTH`): -1 = depends
/// on the content, -2 = invalid.
const te_length = [128]i8{
    24, 20, 6,  11, 6,  10, 12, 17, 16, 6,  6,  6,  8,  -1, 9,  19,
    -2, 10, 16, 24, 24, 24, 10, 11, 16, 19, -2, 12, 16, -1, 19, 17,
    -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
    -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
    -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
    -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -2,
    -2, -2, -2, 2,  10, 14, 12, 14, 9,  5,  17, 13, 24, 9,  17, 7,
    10, 19, 19, 12, 7,  7,  9,  16, 18, 6,  10, 13, 7,  1,  18, 15,
};
const te_bspdecal = 13;
const te_textmessage = 29;

/// ReHLTV `ParseTempEntity`.
fn skipTempEntity(r: *BitReader) Error!void {
    const te_type = try r.readByte();
    if (te_type >= te_length.len) return error.BadTempEntity;
    switch (te_length[te_type]) {
        -2 => return error.BadTempEntity,
        -1 => switch (te_type) {
            te_bspdecal => {
                try r.skipBytes(8); // origin, decal index
                if (try r.readShort() != 0) try r.skipBytes(2); // entity, model
            },
            te_textmessage => {
                try r.skipBytes(5); // channel, x, y
                if (try r.readByte() == 2) try r.skipBytes(2); // effect 2: fx time
                try r.skipBytes(14); // colors, fade in, fade out, hold time
                _ = try r.string();
            },
            else => return error.BadTempEntity,
        },
        else => |len| try r.skipBytes(@intCast(len)),
    }
}

/// ReHLTV `ParseHLTV`.
fn parseHltv(p: *Parser, r: *BitReader) Error!void {
    switch (try r.readByte()) {
        0 => p.is_hltv = true, // HLTV_ACTIVE
        1 => try r.skipBytes(2 + 4 + 4), // HLTV_STATUS: proxies, slots, spectators
        2 => {}, // HLTV_LISTEN
        else => return error.BadHltvCommand,
    }
}

/// ReHLTV `ParseClientData` / `World::ParseClientData`. Empty in HLTV
/// streams.
fn skipClientData(p: *Parser, r: *BitReader) Error!void {
    if (p.is_hltv) return;
    if (try r.readBit()) try r.skipBits(8); // delta sequence
    try delta.skip(r, try p.table(table_client));
    while (try r.readBit()) {
        try r.skipBits(6); // weapon index
        try delta.skip(r, try p.table(table_weapon));
    }
    r.alignByte();
}

/// `svc_event` as the engine writes it (`SV_EmitEvents`): the args flag is
/// only there when a packet index is. (ReHLTV `ParseEvent` reads it either
/// way.)
fn skipEvent(p: *Parser, r: *BitReader) Error!void {
    const count = try r.readBits(5);
    for (0..count) |_| {
        try r.skipBits(10); // event index
        if (try r.readBit()) {
            try r.skipBits(11); // packet index
            if (try r.readBit()) try delta.skip(r, try p.table(table_event));
        }
        if (try r.readBit()) try r.skipBits(16); // fire time
    }
    r.alignByte();
}

/// ReHLTV `ParseEventReliable`.
fn skipEventReliable(p: *Parser, r: *BitReader) Error!void {
    try r.skipBits(10); // event index
    try delta.skip(r, try p.table(table_event));
    if (try r.readBit()) try r.skipBits(16); // fire time
    r.alignByte();
}

/// ReHLTV `World::ParseBaseline`. Keeps the instanced baseline count.
fn parseSpawnBaseline(p: *Parser, r: *BitReader) Error!void {
    const entity_beam = 1 << 1;
    while (try r.peekBits(16) != 0xffff) {
        const index = try r.readBits(11);
        const entity_type = try r.readBits(2);
        try delta.skip(r, try p.entityTable(index, entity_type & entity_beam != 0));
    }
    try r.skipBits(16);
    const instanced = try r.readBits(6);
    p.instanced_baselines = @intCast(instanced);
    for (0..instanced) |_| try delta.skip(r, try p.table(table_entity));
    r.alignByte();
}

/// The entity list of `svc_packetentities` (`full`) and
/// `svc_deltapacketentities` (ReHLTV `World::ParseDeltaHeader`,
/// `UncompressEntitiesFromStream`; engine `SV_WriteDeltaHeader`). Ends with
/// 16 zero bits.
fn skipEntities(p: *Parser, r: *BitReader, full: bool) Error!void {
    var numbase: u32 = 0;
    while (try r.peekBits(16) != 0) {
        // Full updates: "next entity" flag. Deltas: "removed" flag.
        const flag = try r.readBit();
        const next_entity = full and flag;
        const remove = !full and flag;
        const num: u32 = if (next_entity)
            numbase + 1
        else if (try r.readBit())
            try r.readBits(11)
        else
            numbase +% try r.readBits(6);
        numbase = num;
        if (remove) continue;
        const custom = try r.readBit();
        var new_baseline = false;
        if (p.instanced_baselines != 0) {
            new_baseline = try r.readBit();
            if (new_baseline) try r.skipBits(6);
        }
        if (full and !new_baseline) {
            if (try r.readBit()) try r.skipBits(6); // baseline offset
        }
        try delta.skip(r, try p.entityTable(num, custom));
    }
    if (try r.readBits(16) != 0) return error.BadEntityListEnd;
    r.alignByte();
}

/// ReHLTV `ParseSound`.
fn skipSound(r: *BitReader) Error!void {
    const volume = 1 << 0;
    const attenuation = 1 << 1;
    const large_index = 1 << 2;
    const pitch = 1 << 3;
    const mask = try r.readBits(9);
    if (mask & volume != 0) try r.skipBits(8);
    if (mask & attenuation != 0) try r.skipBits(8);
    try r.skipBits(3 + 11 + 8); // channel, entity, sound index
    if (mask & large_index != 0) try r.skipBits(8);
    _ = try r.readBitVec3Coord();
    if (mask & pitch != 0) try r.skipBits(8);
    r.alignByte();
}

/// ReHLTV `ParsePings`: entries of 24 bits while a 1 bit precedes them.
fn skipPings(r: *BitReader) Error!void {
    while (try r.readBit()) try r.skipBits(24);
    r.alignByte();
}

/// ReHLTV `ParseResourceList`.
fn skipResourceList(r: *BitReader) Error!void {
    const res_custom = 1 << 2;
    const total = try r.readBits(12);
    for (0..total) |_| {
        try r.skipBits(4); // type
        try r.skipBitString(); // file name
        try r.skipBits(12 + 24); // index, download size
        if (try r.readBits(3) & res_custom != 0) try r.skipBits(16 * 8); // MD5
        if (try r.readBit()) try r.skipBits(32 * 8); // reserved
    }
    // Consistency list.
    if (try r.readBit()) {
        while (try r.readBit()) try r.skipBits(if (try r.readBit()) 5 else 10);
    }
    r.alignByte();
}

/// A network frame whose messages failed to parse, past the point of
/// failure. Its later messages (possibly voice) are lost.
pub const FrameFailure = struct {
    entry: u32,
    /// Index of the frame in its entry.
    index: u32,
    time: f32,
    /// File offset of the frame.
    frame_offset: usize,
    /// Length of the frame's message data.
    frame_len: usize,
    failure: Failure,
};

/// A message and the frame it came from.
pub const FrameMessage = struct {
    frame: demo.Frame,
    message: Message,
};

/// Walks every message of every network frame of a demo, in order. A frame
/// that fails to parse is recorded in `failures` and the walk goes on with
/// the next frame (per-frame error isolation).
pub const DemoMessages = struct {
    parser: Parser,
    frames: demo.FrameIterator,
    failures: std.ArrayList(FrameFailure) = .empty,
    current: ?struct { frame: demo.Frame, messages: MessageIterator } = null,

    pub fn init(gpa: std.mem.Allocator, d: demo.Demo) DemoMessages {
        return .{ .parser = .init(gpa), .frames = d.frames() };
    }

    pub fn deinit(w: *DemoMessages) void {
        w.failures.deinit(w.parser.gpa);
        w.parser.deinit();
    }

    /// The next message, or null when the demo is done (then check
    /// `failures` and `frames.problem`). Only fails on out of memory.
    pub fn next(w: *DemoMessages) error{OutOfMemory}!?FrameMessage {
        while (true) {
            if (w.current) |*c| {
                if (c.messages.next()) |maybe| {
                    if (maybe) |msg| return .{ .frame = c.frame, .message = msg };
                } else |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    try w.failures.append(w.parser.gpa, .{
                        .entry = c.frame.entry,
                        .index = c.frame.index,
                        .time = c.frame.time,
                        .frame_offset = c.frame.offset,
                        .frame_len = c.frame.data.len,
                        .failure = c.messages.failure.?,
                    });
                }
                w.current = null;
            }
            const f = w.frames.next() orelse return null;
            if (!f.type.isNetwork()) continue;
            w.current = .{ .frame = f, .messages = w.parser.frame(f.data) };
        }
    }
};

const testing = std.testing;
const BitWriter = bits.BitWriter;

/// `n` copies of `c`, comptime-known (`**` is gone in Zig 0.17).
inline fn rep(comptime c: u8, comptime n: usize) *const [n]u8 {
    comptime {
        const a: [n]u8 = @splat(c);
        return &a;
    }
}

/// Parses `bytes`: one message (id first) followed by an `svc_nop`. Checks
/// the message ends exactly where the nop starts. The message borrows
/// `bytes`.
fn expectOne(p: *Parser, bytes: []const u8) !Message {
    try testing.expectEqual(@as(u8, @backingInt(Id.nop)), bytes[bytes.len - 1]);
    var it = p.frame(bytes);
    const msg = (try it.next()).?;
    try testing.expectEqual(Message{ .engine = .nop }, (try it.next()).?);
    try testing.expectEqual(@as(?Message, null), try it.next());
    return msg;
}

fn expectEngine(p: *Parser, id: Id, payload: []const u8) !void {
    const gpa = testing.allocator;
    const buf = try std.mem.concat(gpa, u8, &.{ &.{@backingInt(id)}, payload, &.{@backingInt(Id.nop)} });
    defer gpa.free(buf);
    try testing.expectEqual(Message{ .engine = id }, try expectOne(p, buf));
}

fn expectError(p: *Parser, bytes: []const u8, err: Error) !void {
    var it = p.frame(bytes);
    try testing.expectError(err, it.next());
    try testing.expectEqual(err, it.failure.?.err);
}

test "byte-level engine messages" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const cases = [_]struct { id: Id, payload: []const u8 }{
        .{ .id = .nop, .payload = "" },
        .{ .id = .disconnect, .payload = "bye\x00" },
        .{ .id = .version, .payload = "\x30\x00\x00\x00" },
        .{ .id = .setview, .payload = "\x01\x00" },
        .{ .id = .time, .payload = "\x00\x00\x80\x3f" },
        .{ .id = .print, .payload = "\x02hello\n\x00" },
        .{ .id = .stufftext, .payload = "echo hi\n\x00" },
        .{ .id = .setangle, .payload = "abcdef" },
        .{ .id = .lightstyle, .payload = "\x00mmnmmommommnonmmonqnmmo\x00" },
        .{ .id = .stopsound, .payload = "\x05\x00" },
        .{ .id = .particle, .payload = "0123456789a" },
        .{ .id = .damage, .payload = "" },
        .{ .id = .setpause, .payload = "\x01" },
        .{ .id = .signonnum, .payload = "\x02" },
        .{ .id = .centerprint, .payload = "\x00" },
        .{ .id = .killedmonster, .payload = "" },
        .{ .id = .foundsecret, .payload = "" },
        .{ .id = .spawnstaticsound, .payload = "0123456789abcd" },
        .{ .id = .intermission, .payload = "" },
        .{ .id = .finale, .payload = "the end\x00" },
        .{ .id = .cdtrack, .payload = "\x01\x02" },
        .{ .id = .restore, .payload = "save\x00\x02map1\x00map2\x00" },
        .{ .id = .cutscene, .payload = "x\x00" },
        .{ .id = .weaponanim, .payload = "\x01\x02" },
        .{ .id = .decalname, .payload = "\x07{blood1\x00" },
        .{ .id = .roomtype, .payload = "\x01\x00" },
        .{ .id = .addangle, .payload = "\x10\x00" },
        .{ .id = .choke, .payload = "" },
        .{ .id = .resourcerequest, .payload = "\x01\x00\x00\x00\x00\x00\x00\x00" },
        .{ .id = .crosshairangle, .payload = "\x01\x02" },
        .{ .id = .soundfade, .payload = "\x01\x02\x03\x04" },
        .{ .id = .filetxferfailed, .payload = "file.wad\x00" },
        .{ .id = .director, .payload = "\x03abc" },
        .{ .id = .sendextrainfo, .payload = "\x00\x01" },
        .{ .id = .timescale, .payload = "\x00\x00\x80\x3f" },
        .{ .id = .resourcelocation, .payload = "http://x/\x00" },
        .{ .id = .sendcvarvalue, .payload = "sv_cheats\x00" },
        .{ .id = .sendcvarvalue2, .payload = "\x01\x00\x00\x00fps_max\x00" },
        .{ .id = .exec, .payload = "\x00" },
        .{ .id = .exec, .payload = "\x01\x05" },
        .{ .id = .newmovevars, .payload = rep(0x00, 97) ++ "desert\x00" },
        // spawnstatic: 16 bytes, render mode 0 / non-zero with 5 more.
        .{ .id = .spawnstatic, .payload = rep(0x00, 16) ++ "\x00" },
        .{ .id = .spawnstatic, .payload = rep(0x00, 16) ++ "\x01" ++ rep(0x00, 5) },
        // customization: slot, type, name, index, size, flags (RES_CUSTOM: + MD5).
        .{ .id = .customization, .payload = "\x01\x02logo.bmp\x00\x01\x00\x00\x10\x00\x00\x00" },
        .{ .id = .customization, .payload = "\x01\x02logo.bmp\x00\x01\x00\x00\x10\x00\x00\x04" ++ rep('M', 16) },
        // hltv: active, status (10 bytes), listen.
        .{ .id = .hltv, .payload = "\x00" },
        .{ .id = .hltv, .payload = "\x01" ++ rep(0x00, 10) },
        .{ .id = .hltv, .payload = "\x02" },
    };
    for (cases) |c| try expectEngine(&p, c.id, c.payload);
    try testing.expect(p.is_hltv);
}

test "svc_serverinfo keeps maxclients" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const head = "\x30\x00\x00\x00" ++ "\x01\x00\x00\x00" ++ rep(0x00, 4) ++ rep('M', 16) ++ "\x20\x05\x00" ++ "cstrike\x00Server\x00de_dust2\x00\x00";
    try expectEngine(&p, .serverinfo, head ++ "\x00");
    try testing.expectEqual(@as(u8, 32), p.max_clients);
    // With the extra block: flag, length, bytes, 16 bytes.
    try expectEngine(&p, .serverinfo, head ++ "\x01\x03abc" ++ rep('x', 16));
}

test "svc_temp_entity sizes" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    try expectEngine(&p, .temp_entity, "\x00" ++ rep(0x00, 24)); // TE_BEAMPOINTS
    try expectEngine(&p, .temp_entity, "\x7d" ++ "\x00"); // 125: 1 byte
    // TE_BSPDECAL without and with an entity.
    try expectEngine(&p, .temp_entity, "\x0d" ++ rep(0x00, 8) ++ "\x00\x00");
    try expectEngine(&p, .temp_entity, "\x0d" ++ rep(0x00, 8) ++ "\x01\x00\x02\x00");
    // TE_TEXTMESSAGE with effect 0 and effect 2 (fx time).
    try expectEngine(&p, .temp_entity, "\x1d" ++ rep(0x00, 5) ++ "\x00" ++ rep(0x00, 14) ++ "hi\x00");
    try expectEngine(&p, .temp_entity, "\x1d" ++ rep(0x00, 5) ++ "\x02\x00\x00" ++ rep(0x00, 14) ++ "hi\x00");
    try expectError(&p, "\x17\x10", error.BadTempEntity); // type 16: invalid
    try expectError(&p, "\x17\x80", error.BadTempEntity); // >= TE_MAX
}

test "messages we keep" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    const v = try expectOne(&p, "\x35\x02\x03\x00abc" ++ "\x01");
    try testing.expectEqual(@as(u8, 2), v.voice_data.slot);
    try testing.expectEqualStrings("abc", v.voice_data.data);

    const u = try expectOne(&p, "\x0d\x04\x07\x00\x00\x00\\name\\nnra\x00" ++ rep('H', 16) ++ "\x01");
    try testing.expectEqual(@as(u8, 4), u.update_userinfo.slot);
    try testing.expectEqual(@as(u32, 7), u.update_userinfo.user_id);
    try testing.expectEqualStrings("\\name\\nnra", u.update_userinfo.info);

    const vi = try expectOne(&p, "\x34voice_speex\x00\x05" ++ "\x01");
    try testing.expectEqualStrings("voice_speex", vi.voice_init.codec);
    try testing.expectEqual(@as(u8, 5), vi.voice_init.quality);
}

test "user messages" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    try expectEngine(&p, .newusermsg, "\x50\xffTeamInfo\x00\x00\x00\x00\x00\x00\x00\x00");
    try expectEngine(&p, .newusermsg, "\x51\x01Health\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    const t = try expectOne(&p, "\x50\x04\x01CT\x00" ++ "\x01");
    try testing.expectEqualStrings("TeamInfo", t.user.name);
    try testing.expectEqualSlices(u8, "\x01CT\x00", t.user.data);
    const h = try expectOne(&p, "\x51\x64" ++ "\x01");
    try testing.expectEqual(@as(u8, 0x51), h.user.id);
    try testing.expectEqualSlices(u8, "\x64", h.user.data);
    try expectError(&p, "\x52\x00", error.UnknownUserMessage);
}

test "errors stop the frame and say where" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    try expectError(&p, "\x00", error.BadMessage);
    try expectError(&p, "\x3c", error.BadMessage); // reserved 60
    try expectError(&p, "\x32\x07", error.BadHltvCommand);
    try expectError(&p, "\x2e\x20", error.BadCustomization);
    // Cut-off message.
    try expectError(&p, "\x35\x00\x10\x00abc", error.EndOfBuffer);
    try expectError(&p, "\x08no nul", error.EndOfBuffer);
    // A bit message needing a table the demo never sent.
    try expectError(&p, "\x15\x00\x00\x00", error.MissingDeltaTable);

    var it = p.frame("\x01\x07\x00\x00\x00\x00\x01\x32\x09");
    while (it.next() catch null) |_| {}
    const f = it.failure.?;
    try testing.expectEqual(@as(usize, 7), f.offset);
    try testing.expectEqual(@as(u8, 0x32), f.id);
    try testing.expectEqualSlices(u8, &.{ 1, 7, 1 }, f.previousIds());
    try testing.expectEqualStrings("svc_hltv", @as(Id, @fromBackingInt(@intCast(f.id))).name());
}

/// A parser with tiny delta tables for bit-level message tests: every table
/// has one 8-bit field, except the player table which has a 16-bit one (to
/// tell them apart).
fn testParser(gpa: std.mem.Allocator) !Parser {
    var p: Parser = .init(gpa);
    errdefer p.deinit();
    const byte8: delta.Field = .init(@backingInt(delta.FieldType.byte), 8, "x");
    const short16: delta.Field = .init(@backingInt(delta.FieldType.short), 16, "y");
    for ([_][]const u8{ table_entity, table_custom, table_client, table_weapon, table_event }) |name| {
        try p.tables.put(gpa, name, try gpa.dupe(delta.Field, &.{byte8}));
    }
    try p.tables.put(gpa, table_player, try gpa.dupe(delta.Field, &.{short16}));
    p.max_clients = 2;
    return p;
}

/// A delta value for the test tables: mask with field 0 sent, then `n` bits.
fn writeValue(w: *BitWriter, gpa: std.mem.Allocator, n: u6) !void {
    try w.bits(gpa, 1, 3);
    try w.byte(gpa, 1);
    try w.bits(gpa, 0, n);
}

/// Wraps a bit-level body with its id and checks it parses as one message.
fn expectBits(p: *Parser, id: Id, w: *BitWriter) !void {
    w.alignByte();
    try expectEngine(p, id, w.slice());
}

test "svc_clientdata: empty in HLTV streams, deltas otherwise" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.bit1(gpa, true);
    try w.byte(gpa, 9); // delta sequence
    try writeValue(&w, gpa, 8); // clientdata
    try w.bit1(gpa, true);
    try w.bits(gpa, 3, 6); // weapon 3
    try writeValue(&w, gpa, 8);
    try w.bit1(gpa, false);
    try expectBits(&p, .clientdata, &w);
    p.is_hltv = true;
    try expectEngine(&p, .clientdata, "");
}

test "svc_event: args only with a packet index" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.bits(gpa, 3, 5);
    // 1: packet index and args, no fire time.
    try w.bits(gpa, 1, 10);
    try w.bit1(gpa, true);
    try w.bits(gpa, 5, 11);
    try w.bit1(gpa, true);
    try writeValue(&w, gpa, 8);
    try w.bit1(gpa, false);
    // 2: packet index, no args, fire time.
    try w.bits(gpa, 2, 10);
    try w.bit1(gpa, true);
    try w.bits(gpa, 5, 11);
    try w.bit1(gpa, false);
    try w.bit1(gpa, true);
    try w.short(gpa, 100);
    // 3: no packet index (so no args flag), no fire time.
    try w.bits(gpa, 3, 10);
    try w.bit1(gpa, false);
    try w.bit1(gpa, false);
    try expectBits(&p, .event, &w);
}

test "svc_event_reliable" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.bits(gpa, 7, 10);
    try writeValue(&w, gpa, 8);
    try w.bit1(gpa, true);
    try w.short(gpa, 1);
    try expectBits(&p, .event_reliable, &w);
}

test "svc_spawnbaseline: player and custom tables, instanced baselines" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.bits(gpa, 1, 11); // player 1: player table (16 bits)
    try w.bits(gpa, 0, 2);
    try writeValue(&w, gpa, 16);
    try w.bits(gpa, 40, 11); // entity 40, beam: custom table
    try w.bits(gpa, 2, 2);
    try writeValue(&w, gpa, 8);
    try w.bits(gpa, 41, 11); // entity 41: entity table
    try w.bits(gpa, 0, 2);
    try writeValue(&w, gpa, 8);
    try w.short(gpa, 0xffff);
    try w.bits(gpa, 2, 6); // 2 instanced baselines
    try writeValue(&w, gpa, 8);
    try writeValue(&w, gpa, 8);
    try expectBits(&p, .spawnbaseline, &w);
    try testing.expectEqual(@as(u8, 2), p.instanced_baselines);
}

test "svc_packetentities: header variants" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    for ([_]u8{ 0, 3 }) |instanced| {
        p.instanced_baselines = instanced;
        var w: BitWriter = .{};
        defer w.deinit(gpa);
        try w.short(gpa, 3); // count
        // Entity 1 (next after 0): player table.
        try w.bit1(gpa, true);
        try w.bit1(gpa, false); // not custom
        if (instanced != 0) try w.bit1(gpa, false);
        try w.bit1(gpa, false); // no offset
        try writeValue(&w, gpa, 16);
        // Entity 20 (absolute), custom, offset 1.
        try w.bit1(gpa, false);
        try w.bit1(gpa, true);
        try w.bits(gpa, 20, 11);
        try w.bit1(gpa, true);
        if (instanced != 0) try w.bit1(gpa, false);
        try w.bit1(gpa, true);
        try w.bits(gpa, 1, 6);
        try writeValue(&w, gpa, 8);
        // Entity 25 (+5), instanced baseline 2 (then no offset flag).
        try w.bit1(gpa, false);
        try w.bit1(gpa, false);
        try w.bits(gpa, 5, 6);
        try w.bit1(gpa, false);
        if (instanced != 0) {
            try w.bit1(gpa, true);
            try w.bits(gpa, 2, 6);
        } else try w.bit1(gpa, false);
        try writeValue(&w, gpa, 8);
        try w.short(gpa, 0);
        try expectBits(&p, .packetentities, &w);
    }
}

test "svc_deltapacketentities: removed entities have no body" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.short(gpa, 2);
    try w.byte(gpa, 7); // delta from
    // Remove entity 30.
    try w.bit1(gpa, true);
    try w.bit1(gpa, true);
    try w.bits(gpa, 30, 11);
    // Update entity 2 (absolute: below numbase): player table, no offset flag.
    try w.bit1(gpa, false);
    try w.bit1(gpa, true);
    try w.bits(gpa, 2, 11);
    try w.bit1(gpa, false);
    try writeValue(&w, gpa, 16);
    try w.short(gpa, 0);
    try expectBits(&p, .deltapacketentities, &w);

    // A non-zero end marker can't happen: the loop only ends on 16 zero
    // bits. Running out of data is the failure.
    try expectError(&p, "\x29\x02\x00\x07\x01", error.EndOfBuffer);
}

test "svc_sound" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    for ([_]u32{ 0, 0b1111 }) |mask| {
        var w: BitWriter = .{};
        defer w.deinit(gpa);
        try w.bits(gpa, mask, 9);
        if (mask & 1 != 0) try w.byte(gpa, 255);
        if (mask & 2 != 0) try w.byte(gpa, 64);
        try w.bits(gpa, 0, 22);
        if (mask & 4 != 0) try w.byte(gpa, 1);
        // Origin: x present (int and frac), y absent, z present (int only).
        try w.bits(gpa, 0b101, 3);
        try w.bits(gpa, 0b11, 2);
        try w.bit1(gpa, false);
        try w.bits(gpa, 100, 12);
        try w.bits(gpa, 3, 3);
        try w.bits(gpa, 0b01, 2);
        try w.bit1(gpa, true);
        try w.bits(gpa, 7, 12);
        if (mask & 8 != 0) try w.byte(gpa, 100);
        try expectBits(&p, .sound, &w);
    }
}

test "svc_pings and svc_resourcelist" {
    const gpa = testing.allocator;
    var p = try testParser(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    for (0..3) |_| {
        try w.bit1(gpa, true);
        try w.bits(gpa, 0x123456, 24);
    }
    try w.bit1(gpa, false);
    try expectBits(&p, .pings, &w);

    var rl: BitWriter = .{};
    defer rl.deinit(gpa);
    try rl.bits(gpa, 2, 12);
    // Resource 1: plain.
    try rl.bits(gpa, 1, 4);
    try rl.string(gpa, "sound/a.wav");
    try rl.bits(gpa, 1, 12);
    try rl.bits(gpa, 0, 24);
    try rl.bits(gpa, 0, 3);
    try rl.bit1(gpa, false);
    // Resource 2: custom (MD5) with reserved bytes.
    try rl.bits(gpa, 2, 4);
    try rl.string(gpa, "logo");
    try rl.bits(gpa, 2, 12);
    try rl.bits(gpa, 100, 24);
    try rl.bits(gpa, 4, 3);
    for (0..16) |_| try rl.byte(gpa, 0xaa);
    try rl.bit1(gpa, true);
    for (0..32) |_| try rl.byte(gpa, 0);
    // Consistency list: short then long entries.
    try rl.bit1(gpa, true);
    try rl.bit1(gpa, true);
    try rl.bit1(gpa, true);
    try rl.bits(gpa, 3, 5);
    try rl.bit1(gpa, true);
    try rl.bit1(gpa, false);
    try rl.bits(gpa, 300, 10);
    try rl.bit1(gpa, false);
    try expectBits(&p, .resourcelist, &rl);
}

test "svc_deltadescription goes into the parser's tables" {
    const gpa = testing.allocator;
    var p: Parser = .init(gpa);
    defer p.deinit();
    var w: BitWriter = .{};
    defer w.deinit(gpa);
    try w.string(gpa, "event_t");
    try w.short(gpa, 1);
    try w.bits(gpa, 1, 3); // meta mask: fields 0 and 4
    try w.byte(gpa, 0b1_0001);
    try w.long(gpa, @backingInt(delta.FieldType.integer));
    try w.byte(gpa, 11);
    try expectBits(&p, .deltadescription, &w);
    try testing.expectEqual(@as(u8, 11), p.tables.get("event_t").?[0].bits);
}

test "DemoMessages: a bad frame is recorded and the next frames still parse" {
    const gpa = testing.allocator;
    var d: demo.TestDemo = try .init(gpa);
    defer d.deinit(gpa);
    try d.network(gpa, 0, 0, "\x01");
    try d.frame(gpa, 5, 0, ""); // next section
    try d.network(gpa, 1, 1.5, "\x35\x00\x01\x00A");
    try d.frame(gpa, 4, 1.5, &@as([32]u8, @splat(0))); // client data
    // Voice, then svc_bad: the frame fails at offset 6.
    try d.network(gpa, 1, 2.5, "\x35\x01\x01\x00B\x01\x00\x35\x02\x01\x00C");
    try d.network(gpa, 1, 3.5, "\x35\x03\x01\x00D");

    const opened: demo.Demo = try .open(d.buf.items);
    var w: DemoMessages = .init(gpa, opened);
    defer w.deinit();
    var voices: std.ArrayList(u8) = .empty;
    defer voices.deinit(gpa);
    while (try w.next()) |fm| switch (fm.message) {
        .voice_data => |v| try voices.append(gpa, v.data[0]),
        else => {},
    };
    // B (before the error) is seen, C (after it) is lost, D parses.
    try testing.expectEqualStrings("ABD", voices.items);
    try testing.expectEqual(@as(usize, 1), w.failures.items.len);
    const f = w.failures.items[0];
    try testing.expectEqual(@as(u32, 1), f.entry);
    try testing.expectEqual(@as(u32, 2), f.index);
    try testing.expectEqual(@as(f32, 2.5), f.time);
    try testing.expectEqual(@as(usize, 6), f.failure.offset);
    try testing.expectEqual(@as(u8, 0), f.failure.id);
    try testing.expectEqual(error.BadMessage, f.failure.err);
    try testing.expectEqualSlices(u8, &.{ 0x35, 0x01 }, f.failure.previousIds());
    try testing.expectEqual(@as(usize, 12), f.frame_len);
    try testing.expectEqual(@as(?demo.ScanProblem, null), w.frames.problem);
}
