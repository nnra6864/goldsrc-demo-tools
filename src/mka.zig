//! Matroska audio output: one Opus track per output track (DESIGN.md
//! "Output", doc/FORMAT.md "Matroska output"). Never sees the demo format.

const std = @import("std");
const opus = @import("opus.zig");

/// Input sample rate of the timelines.
pub const input_rate = 24000;
/// Output bit rate per track.
pub const bitrate = 48000;
/// 20 ms frames.
pub const frame_samples = input_rate / 50;
pub const frame_ms = 20;
/// Start a new cluster after this long.
const cluster_ms = 5000;

/// One encoded track, ready to write. Holds its own memory.
pub const EncodedTrack = struct {
    /// Track name, valid UTF-8. Owned.
    name: []u8,
    /// Written as tag `STEAMID` when not empty. Owned.
    steamid: []u8,
    /// Opus packets back to back; packet `i` is `bytes[ends[i-1]..ends[i]]`,
    /// covering `[i * 20 ms, (i + 1) * 20 ms)`.
    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(u32) = .empty,
    /// Encoder delay at 48 kHz (OpusHead pre-skip).
    pre_skip: u16,

    pub fn deinit(t: *EncodedTrack, gpa: std.mem.Allocator) void {
        gpa.free(t.name);
        gpa.free(t.steamid);
        t.bytes.deinit(gpa);
        t.ends.deinit(gpa);
    }

    pub fn packetCount(t: EncodedTrack) usize {
        return t.ends.items.len;
    }

    pub fn packet(t: EncodedTrack, i: usize) []const u8 {
        const start = if (i == 0) 0 else t.ends.items[i - 1];
        return t.bytes.items[start..t.ends.items[i]];
    }
};

/// Encodes a mono 24 kHz timeline to Opus at `bitrate`, fed in pieces of
/// any length, so a long timeline never has to be in memory at once.
pub const TrackEncoder = struct {
    enc: opus.Encoder,
    track: EncodedTrack,
    /// Encoder delay at 24 kHz, flushed out with silence at the end.
    delay: u32,
    frame: [frame_samples]f32 = undefined,
    /// Samples in `frame` so far.
    fill: usize = 0,
    finished: bool = false,

    pub fn init(gpa: std.mem.Allocator, name: []const u8, steamid: []const u8) !TrackEncoder {
        var enc: opus.Encoder = try .init(input_rate, bitrate);
        errdefer enc.deinit();
        const delay = try enc.lookahead();
        const owned_name = try utf8Lossy(gpa, name);
        errdefer gpa.free(owned_name);
        return .{
            .enc = enc,
            .delay = delay,
            .track = .{
                .name = owned_name,
                .steamid = try gpa.dupe(u8, steamid),
                .pre_skip = @intCast(delay * (48000 / input_rate)),
            },
        };
    }

    /// Frees the track too unless `finish` handed it out.
    pub fn deinit(e: *TrackEncoder, gpa: std.mem.Allocator) void {
        e.enc.deinit();
        if (!e.finished) e.track.deinit(gpa);
    }

    /// Encodes the next samples of the timeline.
    pub fn feed(e: *TrackEncoder, gpa: std.mem.Allocator, pcm: []const f32) !void {
        for (pcm) |x| {
            e.frame[e.fill] = std.math.clamp(x, -1, 1);
            e.fill += 1;
            if (e.fill == frame_samples) try e.encodeFrame(gpa);
        }
    }

    fn encodeFrame(e: *TrackEncoder, gpa: std.mem.Allocator) !void {
        var out: [1500]u8 = undefined;
        const n = try e.enc.encode(&e.frame, &out);
        try e.track.bytes.appendSlice(gpa, out[0..n]);
        try e.track.ends.append(gpa, @intCast(e.track.bytes.items.len));
        e.fill = 0;
    }

    /// Pads with silence so the encoder delay is flushed out, and returns
    /// the track. The caller owns it; `deinit` still frees the encoder.
    pub fn finish(e: *TrackEncoder, gpa: std.mem.Allocator) !EncodedTrack {
        std.debug.assert(!e.finished);
        var left: usize = e.delay;
        while (left != 0) {
            const n = @min(left, frame_samples - e.fill);
            @memset(e.frame[e.fill..][0..n], 0);
            e.fill += n;
            left -= n;
            if (e.fill == frame_samples) try e.encodeFrame(gpa);
        }
        if (e.fill != 0) {
            @memset(e.frame[e.fill..], 0);
            try e.encodeFrame(gpa);
        }
        e.finished = true;
        return e.track;
    }
};

/// Encodes a whole mono 24 kHz timeline (see `TrackEncoder`).
pub fn encodeTrack(gpa: std.mem.Allocator, name: []const u8, steamid: []const u8, pcm: []const f32) !EncodedTrack {
    var e: TrackEncoder = try .init(gpa, name, steamid);
    defer e.deinit(gpa);
    try e.feed(gpa, pcm);
    return e.finish(gpa);
}

/// Copies `s`, replacing invalid UTF-8 with U+FFFD (player names are raw
/// bytes; Matroska strings are UTF-8).
pub fn utf8Lossy(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (len != 0 and i + len <= s.len and (if (std.unicode.utf8Decode(s[i..][0..len])) |_| true else |_| false)) {
            try out.appendSlice(gpa, s[i..][0..len]);
            i += len;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

// EBML / Matroska element ids.
const id = struct {
    const ebml = 0x1A45DFA3;
    const ebml_version = 0x4286;
    const ebml_read_version = 0x42F7;
    const ebml_max_id_length = 0x42F2;
    const ebml_max_size_length = 0x42F3;
    const doc_type = 0x4282;
    const doc_type_version = 0x4287;
    const doc_type_read_version = 0x4285;
    const segment = 0x18538067;
    const info = 0x1549A966;
    const timestamp_scale = 0x2AD7B1;
    const duration = 0x4489;
    const title = 0x7BA9;
    const muxing_app = 0x4D80;
    const writing_app = 0x5741;
    const tracks = 0x1654AE6B;
    const track_entry = 0xAE;
    const track_number = 0xD7;
    const track_uid = 0x73C5;
    const track_type = 0x83;
    const flag_lacing = 0x9C;
    const name = 0x536E;
    const codec_id = 0x86;
    const codec_private = 0x63A2;
    const codec_delay = 0x56AA;
    const seek_pre_roll = 0x56BB;
    const audio = 0xE1;
    const sampling_frequency = 0xB5;
    const channels = 0x9F;
    const tags = 0x1254C367;
    const tag = 0x7373;
    const targets = 0x63C0;
    const tag_track_uid = 0x63C5;
    const simple_tag = 0x67C8;
    const tag_name = 0x45A3;
    const tag_string = 0x4487;
    const cluster = 0x1F43B675;
    const timestamp = 0xE7;
    const simple_block = 0xA3;
};

/// Builds EBML in memory. Master elements get an 8-byte size patched in
/// when they end.
const Ebml = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn writeId(e: *Ebml, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        const skip: usize = if (v > 0xFFFFFF) 0 else if (v > 0xFFFF) 1 else if (v > 0xFF) 2 else 3;
        try e.buf.appendSlice(e.gpa, b[skip..]);
    }

    /// Size as an EBML variable-length integer (shortest form).
    fn writeSize(e: *Ebml, n: u64) !void {
        var len: u4 = 1;
        while (len < 8 and n >= (@as(u64, 1) << (7 * @as(u6, len))) - 1) len += 1;
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, n | (@as(u64, 1) << (7 * @as(u6, len))), .big);
        try e.buf.appendSlice(e.gpa, b[8 - @as(usize, len) ..]);
    }

    fn begin(e: *Ebml, v: u32) !usize {
        try e.writeId(v);
        try e.buf.appendNTimes(e.gpa, 0, 8);
        return e.buf.items.len;
    }

    fn end(e: *Ebml, start: usize) void {
        const n: u64 = e.buf.items.len - start;
        std.mem.writeInt(u64, e.buf.items[start - 8 ..][0..8], n | (@as(u64, 1) << 56), .big);
    }

    fn uint(e: *Ebml, v: u32, x: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, x, .big);
        var skip: usize = 0;
        while (skip < 7 and b[skip] == 0) skip += 1;
        try e.bytes(v, b[skip..]);
    }

    fn float(e: *Ebml, v: u32, x: f64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, @bitCast(x), .big);
        try e.bytes(v, &b);
    }

    fn bytes(e: *Ebml, v: u32, data: []const u8) !void {
        try e.writeId(v);
        try e.writeSize(data.len);
        try e.buf.appendSlice(e.gpa, data);
    }
};

/// The 19-byte OpusHead for a mono track.
fn opusHead(pre_skip: u16) [19]u8 {
    var h: [19]u8 = undefined;
    @memcpy(h[0..8], "OpusHead");
    h[8] = 1; // version
    h[9] = 1; // channels
    std.mem.writeInt(u16, h[10..12], pre_skip, .little);
    std.mem.writeInt(u32, h[12..16], input_rate, .little);
    std.mem.writeInt(i16, h[16..18], 0, .little); // output gain
    h[18] = 0; // mapping family
    return h;
}

/// Writes a Matroska file with `tracks` to `w`. `duration_ms` is the
/// length to announce; `title` the segment title.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, title: []const u8, duration_ms: f64, tracks: []const EncodedTrack) !void {
    var e: Ebml = .{ .gpa = gpa };
    defer e.buf.deinit(gpa);

    const header = try e.begin(id.ebml);
    try e.uint(id.ebml_version, 1);
    try e.uint(id.ebml_read_version, 1);
    try e.uint(id.ebml_max_id_length, 4);
    try e.uint(id.ebml_max_size_length, 8);
    try e.bytes(id.doc_type, "matroska");
    try e.uint(id.doc_type_version, 4);
    try e.uint(id.doc_type_read_version, 2);
    e.end(header);

    const segment = try e.begin(id.segment);

    const info = try e.begin(id.info);
    try e.uint(id.timestamp_scale, 1_000_000);
    try e.float(id.duration, duration_ms);
    const safe_title = try utf8Lossy(gpa, title);
    defer gpa.free(safe_title);
    try e.bytes(id.title, safe_title);
    try e.bytes(id.muxing_app, "goldsrc-hltv-voice");
    try e.bytes(id.writing_app, "goldsrc-hltv-voice");
    e.end(info);

    const tracks_el = try e.begin(id.tracks);
    for (tracks, 1..) |t, n| {
        const entry = try e.begin(id.track_entry);
        try e.uint(id.track_number, n);
        try e.uint(id.track_uid, n);
        try e.uint(id.track_type, 2); // audio
        try e.uint(id.flag_lacing, 0);
        try e.bytes(id.name, t.name);
        try e.bytes(id.codec_id, "A_OPUS");
        try e.bytes(id.codec_private, &opusHead(t.pre_skip));
        try e.uint(id.codec_delay, @as(u64, t.pre_skip) * 1_000_000_000 / 48000);
        try e.uint(id.seek_pre_roll, 80_000_000);
        const audio = try e.begin(id.audio);
        try e.float(id.sampling_frequency, 48000);
        try e.uint(id.channels, 1);
        e.end(audio);
        e.end(entry);
    }
    e.end(tracks_el);

    const tags = try e.begin(id.tags);
    for (tracks, 1..) |t, n| {
        if (t.steamid.len == 0) continue;
        const tag = try e.begin(id.tag);
        const targets = try e.begin(id.targets);
        try e.uint(id.tag_track_uid, n);
        e.end(targets);
        const simple = try e.begin(id.simple_tag);
        try e.bytes(id.tag_name, "STEAMID");
        try e.bytes(id.tag_string, t.steamid);
        e.end(simple);
        e.end(tag);
    }
    e.end(tags);

    // Clusters: every track's packet k at k * 20 ms, interleaved by time.
    var longest: usize = 0;
    for (tracks) |t| longest = @max(longest, t.packetCount());
    var k: usize = 0;
    while (k < longest) {
        const cluster_start_ms = k * frame_ms;
        const cluster = try e.begin(id.cluster);
        try e.uint(id.timestamp, cluster_start_ms);
        while (k < longest and k * frame_ms - cluster_start_ms < cluster_ms) : (k += 1) {
            for (tracks, 1..) |t, n| {
                if (k >= t.packetCount()) continue;
                const data = t.packet(k);
                try e.writeId(id.simple_block);
                try e.writeSize(1 + 2 + 1 + data.len);
                try e.buf.append(gpa, @intCast(0x80 | n)); // track number, 1-byte vint (< 127 tracks)
                var rel: [2]u8 = undefined;
                std.mem.writeInt(i16, &rel, @intCast(k * frame_ms - cluster_start_ms), .big);
                try e.buf.appendSlice(gpa, &rel);
                try e.buf.append(gpa, 0x80); // keyframe
                try e.buf.appendSlice(gpa, data);
            }
        }
        e.end(cluster);
    }
    e.end(segment);

    try w.writeAll(e.buf.items);
}

/// Most tracks a file can have (track numbers are written as 1-byte vints).
pub const max_tracks = 126;

const testing = std.testing;

test "utf8Lossy" {
    const gpa = testing.allocator;
    const ok = try utf8Lossy(gpa, "nnra \u{2626}");
    defer gpa.free(ok);
    try testing.expectEqualStrings("nnra \u{2626}", ok);
    const bad = try utf8Lossy(gpa, "a\xffb\xe2\x98");
    defer gpa.free(bad);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}\u{FFFD}", bad);
}

test "EBML sizes and ids" {
    const gpa = testing.allocator;
    var e: Ebml = .{ .gpa = gpa };
    defer e.buf.deinit(gpa);
    try e.writeSize(0);
    try e.writeSize(126);
    try e.writeSize(127); // 0x7F is reserved in 1 byte: needs 2
    try e.writeSize(300);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0xFE, 0x40, 0x7F, 0x41, 0x2C }, e.buf.items);
    e.buf.clearRetainingCapacity();
    try e.uint(id.track_number, 3);
    try e.uint(id.timestamp, 0);
    try e.uint(id.timestamp_scale, 1_000_000);
    try testing.expectEqualSlices(u8, &.{ 0xD7, 0x81, 0x03, 0xE7, 0x81, 0x00, 0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40 }, e.buf.items);
}

/// Runs a program, null if it isn't installed.
fn runTool(gpa: std.mem.Allocator, cwd: std.Io.Dir, argv: []const []const u8) !?std.process.RunResult {
    return std.process.run(gpa, testing.io, .{ .argv = argv, .cwd = .{ .dir = cwd } }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

test "ffprobe reads tracks, names, tags and duration; ffmpeg decodes cleanly" {
    const gpa = testing.allocator;
    // Two tracks: a tone at 1..2 s, and silence; 3 s long.
    const len = 3 * input_rate;
    const pcm = try gpa.alloc(f32, len);
    defer gpa.free(pcm);
    @memset(pcm, 0);
    for (input_rate..2 * input_rate) |i| pcm[i] = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    var tracks = [_]EncodedTrack{
        try encodeTrack(gpa, "nnra", "76561199487820327", pcm),
        try encodeTrack(gpa, "slot 3 \xff", "", pcm[0..input_rate]),
    };
    defer for (&tracks) |*t| t.deinit(gpa);
    try testing.expectEqual(@as(usize, (len + @as(usize, tracks[0].pre_skip / 2) + frame_samples - 1) / frame_samples), tracks[0].packetCount());

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, "test-demo", 3000, &tracks);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out.mka", .data = out.written() });

    const probe = (try runTool(gpa, tmp.dir, &.{
        "ffprobe",                                                                                            "-v",  "error",                      "-show_entries",
        "format=duration:format_tags=title:stream=codec_name,sample_rate,channels:stream_tags=title,STEAMID", "-of", "default=noprint_wrappers=1", "out.mka",
    })) orelse return error.SkipZigTest;
    defer gpa.free(probe.stdout);
    defer gpa.free(probe.stderr);
    try testing.expect(probe.term.success());
    try testing.expectEqualStrings("", probe.stderr);
    const want =
        \\codec_name=opus
        \\sample_rate=48000
        \\channels=1
        \\TAG:title=nnra
        \\TAG:STEAMID=76561199487820327
        \\codec_name=opus
        \\sample_rate=48000
        \\channels=1
        \\TAG:title=slot 3 
    ++ "\u{FFFD}\n" ++
        \\duration=3.000000
        \\TAG:title=test-demo
        \\
    ;
    try testing.expectEqualStrings(want, probe.stdout);

    const decode = (try runTool(gpa, tmp.dir, &.{ "ffmpeg", "-v", "error", "-i", "out.mka", "-map", "0", "-f", "null", "-" })) orelse return error.SkipZigTest;
    defer gpa.free(decode.stdout);
    defer gpa.free(decode.stderr);
    try testing.expect(decode.term.success());
    try testing.expectEqualStrings("", decode.stderr);
}

test "TrackEncoder: fed in pieces, same packets as all at once" {
    const gpa = testing.allocator;
    var pcm: [input_rate / 2 + 123]f32 = undefined;
    for (&pcm, 0..) |*x, i| x.* = 0.4 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
    var whole = try encodeTrack(gpa, "p", "1", &pcm);
    defer whole.deinit(gpa);
    for ([_]usize{ 1, 7, 479, 480, 1000 }) |size| {
        var e: TrackEncoder = try .init(gpa, "p", "1");
        defer e.deinit(gpa);
        var i: usize = 0;
        while (i < pcm.len) : (i += size) try e.feed(gpa, pcm[i..@min(i + size, pcm.len)]);
        var t = try e.finish(gpa);
        defer t.deinit(gpa);
        try testing.expectEqual(whole.pre_skip, t.pre_skip);
        try testing.expectEqualSlices(u32, whole.ends.items, t.ends.items);
        try testing.expectEqualSlices(u8, whole.bytes.items, t.bytes.items);
    }
}
