//! libopus wrappers, and the per-player Steam voice decoder (sequence
//! numbers, packet loss concealment, resets). DESIGN.md "Decoding".

const std = @import("std");
const c = @import("c");
const steamvoice = @import("steamvoice.zig");

/// Longest Opus frame: 120 ms at 48 kHz.
pub const max_frame_samples_48k = 5760;

/// Lost frames concealed with Opus PLC per gap; the rest of a longer gap
/// is silence.
pub const max_concealed_frames = 10;

/// Longest gap in a stream's sequence numbers (5 s) still treated as lost
/// frames. A longer jump is a new stream: Steam starts each burst of speech
/// at sequence 0, so a jump this long isn't loss within one.
pub const max_gap_frames = 250;

pub const Error = error{
    /// libopus failed to create a decoder or encoder.
    OpusInit,
    /// libopus rejected a frame.
    OpusDecode,
    OpusEncode,
};

/// A mono libopus decoder.
pub const Decoder = struct {
    st: *c.OpusDecoder,
    rate: u32,

    pub fn init(rate: u32) Error!Decoder {
        var err: c_int = 0;
        const st = c.opus_decoder_create(@intCast(rate), 1, &err) orelse return error.OpusInit;
        if (err != c.OPUS_OK) {
            c.opus_decoder_destroy(st);
            return error.OpusInit;
        }
        return .{ .st = st, .rate = rate };
    }

    pub fn deinit(d: *Decoder) void {
        c.opus_decoder_destroy(d.st);
    }

    /// Decodes one Opus packet into `out` (large enough for 120 ms).
    /// Returns the number of samples.
    pub fn decode(d: *Decoder, data: []const u8, out: []f32) Error!usize {
        const n = c.opus_decode_float(d.st, data.ptr, @intCast(data.len), out.ptr, @intCast(out.len), 0);
        if (n < 0) return error.OpusDecode;
        return @intCast(n);
    }

    /// Conceals one lost frame of `out.len` samples (a multiple of 2.5 ms).
    pub fn conceal(d: *Decoder, out: []f32) Error!usize {
        const n = c.opus_decode_float(d.st, null, 0, out.ptr, @intCast(out.len), 0);
        if (n < 0) return error.OpusDecode;
        return @intCast(n);
    }

    pub fn reset(d: *Decoder) void {
        _ = c.opus_decoder_ctl(d.st, c.OPUS_RESET_STATE);
    }
};

/// A mono libopus encoder.
pub const Encoder = struct {
    st: *c.OpusEncoder,

    /// `rate`: input sample rate. `bitrate` in bits per second.
    pub fn init(rate: u32, bitrate: i32) Error!Encoder {
        var err: c_int = 0;
        const st = c.opus_encoder_create(@intCast(rate), 1, c.OPUS_APPLICATION_AUDIO, &err) orelse return error.OpusInit;
        var e: Encoder = .{ .st = st };
        if (err != c.OPUS_OK or c.opus_encoder_ctl(st, c.OPUS_SET_BITRATE_REQUEST, @as(i32, bitrate)) != c.OPUS_OK) {
            e.deinit();
            return error.OpusInit;
        }
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        c.opus_encoder_destroy(e.st);
    }

    /// Samples (at the input rate) the encoder delays its output by.
    pub fn lookahead(e: *Encoder) Error!u32 {
        var n: i32 = 0;
        if (c.opus_encoder_ctl(e.st, c.OPUS_GET_LOOKAHEAD_REQUEST, &n) != c.OPUS_OK) return error.OpusEncode;
        return @intCast(n);
    }

    /// Encodes one frame (2.5..60 ms of samples) into `out`. Returns the
    /// packet length.
    pub fn encode(e: *Encoder, pcm: []const f32, out: []u8) Error!usize {
        const n = c.opus_encode_float(e.st, pcm.ptr, @intCast(pcm.len), out.ptr, @intCast(out.len));
        if (n < 0) return error.OpusEncode;
        return @intCast(n);
    }
};

/// Decodes one player's Steam voice packets, in order, to mono f32 at
/// `steamvoice.sample_rate`. Opus is stateful and sequence numbers run
/// across packets, so use one per player.
pub const VoiceDecoder = struct {
    opus: Decoder,
    /// Sequence number expected next, null after a reset.
    next_seq: ?u16 = null,
    /// Frames concealed so far.
    concealed: u32 = 0,
    /// Times a sequence went backwards or jumped (a new stream).
    restarts: u32 = 0,
    /// Whether the last decoded packet's audio follows straight on from the
    /// packet before: its first frame continues the same stream (nothing
    /// lost, or lost frames filled in). The timeline then places it right
    /// after the previous audio instead of at its arrival time.
    continued: bool = false,

    pub const DecodeError = Error || error{
        /// A sample rate chunk other than 24000.
        UnsupportedSampleRate,
        /// SILK chunks are not decoded.
        UnsupportedSilk,
        OutOfMemory,
    };

    pub fn init() Error!VoiceDecoder {
        return .{ .opus = try .init(steamvoice.sample_rate) };
    }

    pub fn deinit(v: *VoiceDecoder) void {
        v.opus.deinit();
    }

    fn reset(v: *VoiceDecoder) void {
        v.opus.reset();
        v.next_seq = null;
    }

    /// Appends the packet's samples to `out`. On error, `out` is left as it
    /// was: the packet is lost as a whole.
    pub fn decode(v: *VoiceDecoder, gpa: std.mem.Allocator, packet: steamvoice.Packet, out: *std.ArrayList(f32)) DecodeError!void {
        const start = out.items.len;
        errdefer out.shrinkRetainingCapacity(start);
        v.continued = false;
        var first = true;
        var chunks = packet.chunks();
        while (chunks.next()) |chunk| switch (chunk) {
            .sample_rate => |r| if (r != steamvoice.sample_rate) return error.UnsupportedSampleRate,
            .unknown_0a => {},
            .silence => |n| {
                first = false;
                try out.appendNTimes(gpa, 0, n);
            },
            .silk => return error.UnsupportedSilk,
            .opus_plc => |data| try v.opusFrames(gpa, data, out, &first),
        };
    }

    fn opusFrames(v: *VoiceDecoder, gpa: std.mem.Allocator, chunk: []const u8, out: *std.ArrayList(f32), first: *bool) DecodeError!void {
        var buf: [max_frame_samples_48k]f32 = undefined;
        var frames: steamvoice.OpusFrames = .init(chunk);
        while (frames.next()) |entry| {
            const f = switch (entry) {
                .reset => {
                    v.reset();
                    first.* = false;
                    continue;
                },
                .frame => |f| f,
            };
            var same_stream = false;
            if (v.next_seq) |expected| {
                const lost = f.seq -% expected;
                if (lost > max_gap_frames) {
                    // Went backwards, or jumped too far for loss: a new stream.
                    v.reset();
                    v.restarts += 1;
                } else {
                    same_stream = true;
                    // Lost frames, 20 ms each: a short loss concealed, the
                    // rest of a long one silence.
                    for (0..@min(lost, max_concealed_frames)) |_| {
                        const n = try v.opus.conceal(buf[0..steamvoice.frame_samples]);
                        try out.appendSlice(gpa, buf[0..n]);
                        v.concealed += 1;
                    }
                    if (lost > max_concealed_frames)
                        try out.appendNTimes(gpa, 0, (lost - max_concealed_frames) * steamvoice.frame_samples);
                }
            }
            if (first.*) v.continued = same_stream;
            first.* = false;
            v.next_seq = f.seq +% 1;
            if (f.data.len == 0) continue;
            const n = try v.opus.decode(f.data, &buf);
            try out.appendSlice(gpa, buf[0..n]);
        }
    }
};

const testing = std.testing;
const testdata = @import("testdata.zig");

/// Encodes `count` 20 ms frames of a 440 Hz tone at 24 kHz.
fn encodeTone(e: *Encoder, frames: [][]u8, storage: [][256]u8) !void {
    var pcm: [steamvoice.frame_samples]f32 = undefined;
    for (frames, storage, 0..) |*f, *s, k| {
        for (&pcm, 0..) |*x, i| {
            const t: f32 = @floatFromInt(k * pcm.len + i);
            x.* = 0.3 * @sin(t * 2 * std.math.pi * 440 / steamvoice.sample_rate);
        }
        f.* = s[0..try e.encode(&pcm, s)];
    }
}

/// Builds a Steam voice packet with one Opus chunk of `frames` numbered from
/// `seqs`, a null frame meaning a reset entry.
fn buildPacket(buf: []u8, frames: []const ?[]const u8, seqs: []const u16) []const u8 {
    std.mem.writeInt(u64, buf[0..8], 76561199487820327, .little);
    var n: usize = 8 + 3;
    for (frames, seqs) |maybe, seq| {
        if (maybe) |f| {
            std.mem.writeInt(u16, buf[n..][0..2], @intCast(f.len), .little);
            std.mem.writeInt(u16, buf[n + 2 ..][0..2], seq, .little);
            @memcpy(buf[n + 4 ..][0..f.len], f);
            n += 4 + f.len;
        } else {
            std.mem.writeInt(u16, buf[n..][0..2], 0xffff, .little);
            n += 2;
        }
    }
    buf[8] = 0x06;
    std.mem.writeInt(u16, buf[9..11], @intCast(n - 11), .little);
    std.mem.writeInt(u32, buf[n..][0..4], std.hash.Crc32.hash(buf[0..n]), .little);
    return buf[0 .. n + 4];
}

fn decodeAll(v: *VoiceDecoder, pkt: []const u8) !usize {
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(testing.allocator);
    try v.decode(testing.allocator, try steamvoice.parse(pkt), &out);
    return out.items.len;
}

test "VoiceDecoder: frames, gaps, wraparound, resets" {
    var e: Encoder = try .init(steamvoice.sample_rate, 48000);
    defer e.deinit();
    var storage: [4][256]u8 = undefined;
    var frames: [4][]u8 = undefined;
    try encodeTone(&e, &frames, &storage);
    const fs = steamvoice.frame_samples;
    var buf: [2048]u8 = undefined;

    var v: VoiceDecoder = try .init();
    defer v.deinit();
    // Two frames in sequence across the u16 wrap.
    try testing.expectEqual(@as(usize, 2 * fs), try decodeAll(&v, buildPacket(&buf, &.{ frames[0], frames[1] }, &.{ 0xffff, 0 })));
    // Gap of 3 lost frames (seq 1, 2, 3): concealed, 20 ms each.
    try testing.expectEqual(@as(usize, 4 * fs), try decodeAll(&v, buildPacket(&buf, &.{frames[2]}, &.{4})));
    try testing.expectEqual(@as(u32, 3), v.concealed);
    try testing.expect(v.continued);
    // A long gap (seq 5..104 lost): 10 frames concealed, the other 90 silence,
    // so the frame after it lands 100 frames later.
    const out_len = try decodeAll(&v, buildPacket(&buf, &.{frames[3]}, &.{105}));
    try testing.expectEqual(@as(usize, 101 * fs), out_len);
    try testing.expectEqual(@as(u32, 13), v.concealed);
    try testing.expect(v.continued);
    // A jump over 5 s: a new stream, nothing filled in.
    try testing.expectEqual(@as(usize, fs), try decodeAll(&v, buildPacket(&buf, &.{frames[0]}, &.{1000})));
    try testing.expectEqual(@as(u32, 1), v.restarts);
    try testing.expect(!v.continued);
    // Backwards: a new stream, nothing concealed.
    try testing.expectEqual(@as(usize, fs), try decodeAll(&v, buildPacket(&buf, &.{frames[0]}, &.{5})));
    try testing.expectEqual(@as(u32, 2), v.restarts);
    try testing.expect(!v.continued);
    // A reset entry forgets the sequence: a jump after it is no gap.
    try testing.expectEqual(@as(usize, fs), try decodeAll(&v, buildPacket(&buf, &.{ null, frames[1] }, &.{ 0, 500 })));
    try testing.expectEqual(@as(u32, 13), v.concealed);
    try testing.expect(!v.continued);
    // Empty frames advance the sequence without audio.
    try testing.expectEqual(@as(usize, fs), try decodeAll(&v, buildPacket(&buf, &.{ "", frames[2] }, &.{ 501, 502 })));
    try testing.expectEqual(@as(u32, 13), v.concealed);
    try testing.expect(v.continued);
}

test "VoiceDecoder: a bad frame loses the whole packet" {
    var e: Encoder = try .init(steamvoice.sample_rate, 48000);
    defer e.deinit();
    var storage: [1][256]u8 = undefined;
    var frames: [1][]u8 = undefined;
    try encodeTone(&e, &frames, &storage);
    var buf: [1024]u8 = undefined;
    var v: VoiceDecoder = try .init();
    defer v.deinit();
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, 1);
    // An invalid Opus packet (TOC with code 3 and no frame count byte).
    const bad = "\x03";
    const pkt = try steamvoice.parse(buildPacket(&buf, &.{ frames[0], bad }, &.{ 0, 1 }));
    try testing.expectError(error.OpusDecode, v.decode(testing.allocator, pkt, &out));
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "VoiceDecoder: test demo packets decode to 480 samples per frame plus silence" {
    const gpa = testing.allocator;
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(gpa);
    var total: usize = 0;
    for ([_][]const u8{ "one-player", "rejoin-team-switch" }) |base| {
        // One speaker per demo: one decoder per demo.
        var v: VoiceDecoder = try .init();
        defer v.deinit();
        const text = try testdata.readFixture(gpa, base, ".golden.tsv");
        defer gpa.free(text);
        var rows: testdata.TsvIterator = .init(text);
        while (try rows.next()) |row| {
            if (!std.mem.eql(u8, row[0], "voice")) continue;
            var raw: [2048]u8 = undefined;
            const p = try steamvoice.parse(try std.fmt.hexToBytes(&raw, row[6]));
            var want: usize = 0;
            var it = p.chunks();
            while (it.next()) |ch| switch (ch) {
                .silence => |n| want += n,
                .opus_plc => |d| {
                    var fr: steamvoice.OpusFrames = .init(d);
                    while (fr.next()) |f| switch (f) {
                        .frame => |x| if (x.data.len != 0) {
                            want += steamvoice.frame_samples;
                        },
                        .reset => {},
                    };
                },
                else => {},
            };
            out.clearRetainingCapacity();
            try v.decode(gpa, p, &out);
            try testing.expectEqual(want, out.items.len);
            total += 1;
        }
        // No gaps in the test demos (checked offline too).
        try testing.expectEqual(@as(u32, 0), v.concealed);
    }
    try testing.expectEqual(@as(usize, 426), total);
}
