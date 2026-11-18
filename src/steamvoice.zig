//! Steam voice packets: the `svc_voicedata` payload Steam clients send when
//! the server announces no codec (doc/FORMAT.md "Steam voice"). Format only;
//! decoding is in opus.zig.
//!
//! ```
//! u64 SteamID64, chunks, u32 CRC32 of everything before it
//! chunk: 0x0B u16 sample rate | 0x0A u16 (unknown) | 0x00 u16 silence samples
//!      | 0x04 u16 len, SILK | 0x06 u16 len, Opus PLC frames
//! Opus PLC frame: u16 len, u16 seq, len bytes; len 0xFFFF = reset (no seq)
//! ```

const std = @import("std");

/// The only sample rate seen (and supported).
pub const sample_rate = 24000;
/// Opus frames are 20 ms.
pub const frame_samples = sample_rate / 50;

/// Top 32 bits of an individual account's SteamID64.
const individual_prefix = 0x0110_0001;

pub const Error = error{
    /// Too short, or no individual SteamID first: not a Steam voice packet
    /// (another codec, or garbage).
    NotSteamVoice,
    /// A chunk or Opus frame runs past the end of the packet.
    Truncated,
    /// A chunk type we don't know: the rest of the packet can't be read.
    UnknownChunk,
};

pub const Chunk = union(enum) {
    sample_rate: u16,
    /// Samples of silence.
    silence: u16,
    /// Never seen; not decoded.
    silk: []const u8,
    /// Opus frames, see `OpusFrames`.
    opus_plc: []const u8,
    /// 0x0A with its u16 value; meaning unknown, ignored.
    unknown_0a: u16,
};

/// A parsed packet. Parsing checks the whole structure, so iterating its
/// chunks and Opus frames can't fail.
pub const Packet = struct {
    steamid: u64,
    /// The chunk bytes (between the SteamID and the CRC). Borrowed.
    body: []const u8,
    crc_ok: bool,

    pub fn chunks(p: Packet) Chunks {
        return .{ .rest = p.body };
    }
};

/// Parses and validates a packet: every chunk and every Opus frame must fit.
pub fn parse(data: []const u8) Error!Packet {
    if (data.len < 8 + 4) return error.NotSteamVoice;
    const steamid = std.mem.readInt(u64, data[0..8], .little);
    if (steamid >> 32 != individual_prefix) return error.NotSteamVoice;
    const crc_at = data.len - 4;
    const packet: Packet = .{
        .steamid = steamid,
        .body = data[8..crc_at],
        .crc_ok = std.hash.Crc32.hash(data[0..crc_at]) == std.mem.readInt(u32, data[crc_at..][0..4], .little),
    };
    var it: Chunks = .{ .rest = packet.body };
    while (try it.nextChecked()) |c| switch (c) {
        .opus_plc => |d| {
            var frames: OpusFrames = .{ .rest = d };
            while (try frames.nextChecked()) |_| {}
        },
        else => {},
    };
    return packet;
}

/// Chunks of a parsed packet.
pub const Chunks = struct {
    rest: []const u8,

    /// The next chunk, null at the end. Only for parsed packets.
    pub fn next(it: *Chunks) ?Chunk {
        // parse() already checked the structure; ending early is the safe
        // fallback should that ever not hold.
        return it.nextChecked() catch null;
    }

    fn nextChecked(it: *Chunks) Error!?Chunk {
        if (it.rest.len == 0) return null;
        const op = it.rest[0];
        if (op != 0x0b and op != 0x0a and op != 0x00 and op != 0x04 and op != 0x06) return error.UnknownChunk;
        if (it.rest.len < 3) return error.Truncated;
        const v = std.mem.readInt(u16, it.rest[1..3], .little);
        switch (op) {
            0x0b, 0x0a, 0x00 => {
                it.rest = it.rest[3..];
                return switch (op) {
                    0x0b => .{ .sample_rate = v },
                    0x0a => .{ .unknown_0a = v },
                    else => .{ .silence = v },
                };
            },
            else => {
                if (it.rest.len - 3 < v) return error.Truncated;
                const payload = it.rest[3..][0..v];
                it.rest = it.rest[3 + v ..];
                return if (op == 0x04) .{ .silk = payload } else .{ .opus_plc = payload };
            },
        }
    }
};

/// One entry of an Opus PLC chunk.
pub const OpusFrame = union(enum) {
    /// Length 0xFFFF: reset the decoder.
    reset,
    frame: struct {
        seq: u16,
        /// May be empty (no audio, but the sequence advances).
        data: []const u8,
    },
};

/// Frames of an Opus PLC chunk from a parsed packet.
pub const OpusFrames = struct {
    rest: []const u8,

    pub fn init(chunk: []const u8) OpusFrames {
        return .{ .rest = chunk };
    }

    /// The next frame, null at the end. Only for chunks of parsed packets.
    pub fn next(it: *OpusFrames) ?OpusFrame {
        // parse() already checked the structure; ending early is the safe
        // fallback should that ever not hold.
        return it.nextChecked() catch null;
    }

    fn nextChecked(it: *OpusFrames) Error!?OpusFrame {
        if (it.rest.len == 0) return null;
        if (it.rest.len < 2) return error.Truncated;
        const len = std.mem.readInt(u16, it.rest[0..2], .little);
        if (len == 0xffff) {
            it.rest = it.rest[2..];
            return .reset;
        }
        if (it.rest.len < 4 or it.rest.len - 4 < len) return error.Truncated;
        const seq = std.mem.readInt(u16, it.rest[2..4], .little);
        const data = it.rest[4..][0..len];
        it.rest = it.rest[4 + len ..];
        return .{ .frame = .{ .seq = seq, .data = data } };
    }
};

/// Writes a short description of a packet for `--dump`, like the Rust tool:
/// `steam <id> crc ok [rate=24000 opus=123B]`.
pub fn describe(w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    const p = parse(data) catch |err| return w.print("(not a Steam voice packet: {t})", .{err});
    try w.print("steam {d} crc {s} [", .{ p.steamid, if (p.crc_ok) "ok" else "BAD" });
    var it = p.chunks();
    var first = true;
    while (it.next()) |c| {
        if (!first) try w.writeByte(' ');
        first = false;
        switch (c) {
            .sample_rate => |r| try w.print("rate={d}", .{r}),
            .silence => |n| try w.print("silence={d}", .{n}),
            .silk => |d| try w.print("silk={d}B", .{d.len}),
            .opus_plc => |d| try w.print("opus={d}B", .{d.len}),
            .unknown_0a => |v| try w.print("0x0a={d}", .{v}),
        }
    }
    try w.writeByte(']');
}

const testing = std.testing;
const testdata = @import("testdata.zig");

/// Builds a packet: SteamID, `body`, CRC (correct unless `bad_crc`).
fn build(buf: []u8, body: []const u8, bad_crc: bool) []const u8 {
    std.mem.writeInt(u64, buf[0..8], 76561199487820327, .little);
    @memcpy(buf[8..][0..body.len], body);
    const n = 8 + body.len;
    var crc = std.hash.Crc32.hash(buf[0..n]);
    if (bad_crc) crc ^= 1;
    std.mem.writeInt(u32, buf[n..][0..4], crc, .little);
    return buf[0 .. n + 4];
}

test "parse: chunks and Opus frames" {
    var buf: [64]u8 = undefined;
    const pkt = build(&buf, "\x0b\xc0\x5d" ++ "\x0a\x01\x00" ++ "\x00\x80\x02" ++
        "\x06\x11\x00" ++ "\x02\x00\x07\x00AB" ++ "\xff\xff" ++ "\x00\x00\x09\x00" ++ "\x01\x00\x0a\x00C", false);
    const p = try parse(pkt);
    try testing.expectEqual(@as(u64, 76561199487820327), p.steamid);
    try testing.expect(p.crc_ok);
    var it = p.chunks();
    try testing.expectEqual(Chunk{ .sample_rate = 24000 }, it.next().?);
    try testing.expectEqual(Chunk{ .unknown_0a = 1 }, it.next().?);
    try testing.expectEqual(Chunk{ .silence = 640 }, it.next().?);
    const opus = it.next().?.opus_plc;
    try testing.expectEqual(@as(?Chunk, null), it.next());
    var frames: OpusFrames = .init(opus);
    const f1 = frames.next().?.frame;
    try testing.expectEqual(@as(u16, 7), f1.seq);
    try testing.expectEqualStrings("AB", f1.data);
    try testing.expectEqual(OpusFrame.reset, frames.next().?);
    const f2 = frames.next().?.frame;
    try testing.expectEqual(@as(u16, 9), f2.seq);
    try testing.expectEqual(@as(usize, 0), f2.data.len);
    try testing.expectEqualStrings("C", frames.next().?.frame.data);
    try testing.expectEqual(@as(?OpusFrame, null), frames.next());
}

test "parse: bad CRC is reported, not an error" {
    var buf: [32]u8 = undefined;
    const p = try parse(build(&buf, "\x00\x10\x00", true));
    try testing.expect(!p.crc_ok);
}

test "parse: errors" {
    var buf: [64]u8 = undefined;
    try testing.expectError(error.NotSteamVoice, parse("short"));
    var not_steam = buf;
    const pkt = build(&not_steam, "", false);
    not_steam[7] = 0x02; // another account type
    try testing.expectError(error.NotSteamVoice, parse(pkt));
    try testing.expectError(error.UnknownChunk, parse(build(&buf, "\x0b\xc0\x5d\x07\x00\x00", false)));
    try testing.expectError(error.Truncated, parse(build(&buf, "\x0b\xc0", false)));
    try testing.expectError(error.Truncated, parse(build(&buf, "\x06\x05\x00\x01\x00", false)));
    // Opus frame longer than its chunk.
    try testing.expectError(error.Truncated, parse(build(&buf, "\x06\x05\x00\x09\x00\x01\x00X", false)));
    // A lone byte after the last frame.
    try testing.expectError(error.Truncated, parse(build(&buf, "\x06\x05\x00\x00\x00\x01\x00\x07", false)));
    // Only the SteamID and CRC: valid, no chunks.
    const empty = try parse(build(&buf, "", false));
    var it = empty.chunks();
    try testing.expectEqual(@as(?Chunk, null), it.next());
}

test "describe" {
    var buf: [64]u8 = undefined;
    var out: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try describe(&w, build(&buf, "\x0b\xc0\x5d\x06\x00\x00", false));
    try testing.expectEqualStrings("steam 76561199487820327 crc ok [rate=24000 opus=0B]", w.buffered());
    var w2: std.Io.Writer = .fixed(&out);
    try describe(&w2, "x");
    try testing.expectEqualStrings("(not a Steam voice packet: NotSteamVoice)", w2.buffered());
}

test "every voice packet of the test demos parses, CRC ok, 24 kHz" {
    const gpa = testing.allocator;
    var packets: usize = 0;
    var opus_chunks: usize = 0;
    for (testdata.demos) |base| {
        const text = try testdata.readFixture(gpa, base, ".golden.tsv");
        defer gpa.free(text);
        var rows: testdata.TsvIterator = .init(text);
        while (try rows.next()) |row| {
            if (!std.mem.eql(u8, row[0], "voice")) continue;
            var raw: [2048]u8 = undefined;
            const data = try std.fmt.hexToBytes(&raw, row[6]);
            const p = try parse(data);
            try testing.expect(p.crc_ok);
            var it = p.chunks();
            while (it.next()) |c| switch (c) {
                .sample_rate => |r| try testing.expectEqual(@as(u16, sample_rate), r),
                .opus_plc => opus_chunks += 1,
                .silence => {},
                .silk, .unknown_0a => return error.TestUnexpectedChunk,
            };
            packets += 1;
        }
    }
    // doc/FORMAT.md: 426 packets, 414 Opus chunks.
    try testing.expectEqual(@as(usize, 426), packets);
    try testing.expectEqual(@as(usize, 414), opus_chunks);
}
