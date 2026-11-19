//! goldsrc-demo-tools: tools for GoldSrc demos (DESIGN.md "CLI"). `voice`
//! writes the voice chat to a .mka, one Opus track per player.

const std = @import("std");
const demo = @import("demo.zig");
const messages = @import("messages.zig");
const players = @import("players.zig");
const timeline = @import("timeline.zig");
const mka = @import("mka.zig");
const dump = @import("dump.zig");
const info = @import("info.zig");

pub const usage =
    \\usage: goldsrc-demo-tools <command> <demo.dem> [options]
    \\
    \\  voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump] [--lenient]
    \\      the voice chat as a .mka, one Opus track per player
    \\  info <demo.dem>
    \\      what the demo holds, one "key value" per line: map, duration, directory,
    \\      end (complete or cut-off), players (joined with a SteamID, HLTV not
    \\      counted), unidentified (joined without one, such as bots), then a
    \\      "player <steamid or -> <name>" line each
    \\
;

/// Exit codes.
pub const Exit = enum(u8) {
    ok = 0,
    err = 1,
    usage = 2,
    /// Some of the demo could not be read: voice may be missing.
    partial = 3,
};

/// Options of `voice`.
pub const VoiceOptions = struct {
    demo: []const u8,
    out: ?[]const u8 = null,
    tracks: players.TrackMode = .player,
    order: players.Order = .join,
    dump: bool = false,
    lenient: bool = false,
};

/// Parses `voice`'s arguments (after the command). Null means usage error.
pub fn parseVoiceArgs(args: []const []const u8) ?VoiceOptions {
    var o: VoiceOptions = .{ .demo = "" };
    var have_demo = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i == args.len) return null;
            o.out = args[i];
        } else if (std.mem.eql(u8, a, "--tracks")) {
            i += 1;
            if (i == args.len) return null;
            o.tracks = std.meta.stringToEnum(players.TrackMode, args[i]) orelse return null;
        } else if (std.mem.eql(u8, a, "--order")) {
            i += 1;
            if (i == args.len) return null;
            o.order = std.meta.stringToEnum(players.Order, args[i]) orelse return null;
        } else if (std.mem.eql(u8, a, "--dump")) {
            o.dump = true;
        } else if (std.mem.eql(u8, a, "--lenient")) {
            o.lenient = true;
        } else if (a.len > 1 and a[0] == '-') {
            return null; // -h, --help, unknown flags
        } else if (!have_demo) {
            o.demo = a;
            have_demo = true;
        } else return null;
    }
    return if (have_demo) o else null;
}

/// `path` with its extension replaced by `.mka` (or `.mka` added). Caller
/// frees.
pub fn defaultOutput(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, path[base_start..], '.');
    const stem_end = if (dot) |d| (if (d == 0) path.len else base_start + d) else path.len;
    return std.mem.concat(gpa, u8, &.{ path[0..stem_end], ".mka" });
}

/// File name of `path` without its extension: the segment title.
fn stem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

fn printTime(w: *std.Io.Writer, t: f32) !void {
    try demo.formatTime(w, t);
    try w.writeByte('s');
}

/// Reports what couldn't be read. Returns true if voice may be missing.
fn report(w: *std.Io.Writer, d: demo.Demo, walk: *const messages.DemoMessages, rendered: ?*const timeline.Report) !bool {
    var partial = false;
    const h = d.header;
    if (h.net_protocol != demo.Header.net_protocol_expected or h.demo_protocol != demo.Header.demo_protocol_expected)
        try w.print("warning: demo protocol {d}, net protocol {d} (written for {d} and {d}): messages may not parse\n", .{ h.demo_protocol, h.net_protocol, demo.Header.demo_protocol_expected, demo.Header.net_protocol_expected });
    if (d.directory_problem) |p| switch (p) {
        .missing => try w.writeAll("note: no directory (demo not finalized): reading frames to the end of the file\n"),
        else => try w.print("warning: {s}: reading frames from offset {d} to the end of the file\n", .{ p.describe(), demo.header_size }),
    };
    if (walk.frames.unusual_types != 0)
        try w.print("warning: {d} frames have an unknown type (read as network frames)\n", .{walk.frames.unusual_types});
    if (walk.frames.problem) |p| {
        if (p.isError()) {
            partial = true;
            try w.print("error: {s} at offset {d} (entry {d}, frame {d}, after ", .{ p.describe(), p.offset, p.entry, p.index });
            try printTime(w, p.last_time);
            try w.writeAll("): the rest of the demo is not read\n");
        } else {
            try w.print("warning: {s} at offset {d} (entry {d}, frame {d}, after ", .{ p.describe(), p.offset, p.entry, p.index });
            try printTime(w, p.last_time);
            try w.writeAll("): that frame is lost\n");
        }
    }
    const failures = walk.failures.items;
    if (failures.len != 0) partial = true;
    const shown = @min(failures.len, 20);
    for (failures[0..shown]) |f| {
        const fl = f.failure;
        const name = @as(messages.Id, @fromBackingInt(@intCast(fl.id))).name();
        try w.print("error: frame {d}/{d} at ", .{ f.entry, f.index });
        try printTime(w, f.time);
        try w.print(" (offset {d}): {s} (id {d}) at byte {d} of {d}: {t}; before it:", .{ f.frame_offset, name, fl.id, fl.offset, f.frame_len, fl.err });
        for (fl.previousIds()) |pid| try w.print(" {s}", .{@as(messages.Id, @fromBackingInt(@intCast(pid))).name()});
        try w.writeAll("\n");
    }
    if (failures.len > shown) try w.print("error: ... and {d} more frames\n", .{failures.len - shown});
    if (failures.len != 0) try w.print("error: {d} frames failed to parse: voice in the rest of those frames is lost\n", .{failures.len});

    if (rendered) |r| {
        for (r.lost.items) |lp| {
            try w.print("error: {s} at ", .{lp.player});
            try printTime(w, lp.time);
            try w.print(": voice packet not decoded: {t}\n", .{lp.err});
        }
        if (r.lost.items.len != 0) partial = true;
        if (r.bad_crc != 0) try w.print("warning: {d} voice packets have a bad CRC (decoded anyway)\n", .{r.bad_crc});
    }
    return partial;
}

/// Runs the tool. `args` excludes the program name. Output for the user on
/// `out`, diagnostics on `err`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Exit {
    if (args.len != 0 and std.mem.eql(u8, args[0], "voice")) {
        if (parseVoiceArgs(args[1..])) |o| return runVoice(gpa, io, o, out, err);
    } else if (args.len == 2 and std.mem.eql(u8, args[0], "info") and !isFlag(args[1])) {
        return runInfo(gpa, io, args[1], out, err);
    }
    try err.writeAll(usage);
    return .usage;
}

fn isFlag(a: []const u8) bool {
    return a.len > 1 and a[0] == '-';
}

/// `info`: what the demo holds. Exits `partial` when frames failed to parse:
/// the player counts may then miss someone.
fn runInfo(gpa: std.mem.Allocator, io: std.Io, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !Exit {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        try err.print("goldsrc-demo-tools: {s}: {t}\n", .{ path, e });
        return .err;
    };
    defer gpa.free(data);
    const d = demo.Demo.open(data) catch {
        try err.print("goldsrc-demo-tools: {s}: not a GoldSrc demo\n", .{path});
        return .err;
    };
    var walk: messages.DemoMessages = .init(gpa, d);
    defer walk.deinit();
    var ps: players.Players = .init(gpa);
    defer ps.deinit();
    while (try walk.next()) |fm| try ps.add(fm.frame.time, fm.message);
    try info.write(out, d, &walk, &ps);
    return if (try report(err, d, &walk, null)) .partial else .ok;
}

/// `voice`: the .mka.
fn runVoice(gpa: std.mem.Allocator, io: std.Io, o: VoiceOptions, out: *std.Io.Writer, err: *std.Io.Writer) !Exit {
    const data = std.Io.Dir.cwd().readFileAlloc(io, o.demo, gpa, .unlimited) catch |e| {
        try err.print("goldsrc-demo-tools: {s}: {t}\n", .{ o.demo, e });
        return .err;
    };
    defer gpa.free(data);
    const d = demo.Demo.open(data) catch {
        try err.print("goldsrc-demo-tools: {s}: not a GoldSrc demo\n", .{o.demo});
        return .err;
    };

    var walk: messages.DemoMessages = .init(gpa, d);
    defer walk.deinit();
    var ps: players.Players = .init(gpa);
    defer ps.deinit();
    while (try walk.next()) |fm| try ps.add(fm.frame.time, fm.message);
    const duration = walk.max_time;

    if (o.dump) {
        try dump.write(out, &ps, duration);
        const partial = try report(err, d, &walk, null);
        return if (partial and !o.lenient) .partial else .ok;
    }

    const speakers = try ps.speakers(gpa, o.order);
    defer gpa.free(speakers);
    const track_list = try players.tracks(gpa, speakers, o.tracks);
    defer gpa.free(track_list);
    defer players.freeTracks(gpa, track_list);
    if (track_list.len > mka.max_tracks) {
        try err.print("goldsrc-demo-tools: {d} tracks, at most {d} supported\n", .{ track_list.len, mka.max_tracks });
        return .err;
    }

    // Render and encode track by track.
    var rendered: timeline.Report = .{};
    defer rendered.deinit(gpa);
    var encoded: std.ArrayList(mka.EncodedTrack) = .empty;
    defer {
        for (encoded.items) |*t| t.deinit(gpa);
        encoded.deinit(gpa);
    }
    const len = timeline.length(duration);
    // A chunk at a time too, so memory does not grow with the demo's length.
    const chunk = try gpa.alloc(f32, @min(len, timeline.chunk_samples));
    defer gpa.free(chunk);
    for (track_list) |t| {
        var r: timeline.TrackRenderer = try .init(gpa, t, len);
        defer r.deinit(gpa);
        var e: mka.TrackEncoder = try .init(gpa, t.title, t.steamid);
        defer e.deinit(gpa);
        while (true) {
            const pcm = try r.next(gpa, chunk, &rendered);
            if (pcm.len == 0) break;
            try e.feed(gpa, pcm);
        }
        try encoded.ensureUnusedCapacity(gpa, 1);
        encoded.appendAssumeCapacity(try e.finish(gpa));
    }

    const partial = try report(err, d, &walk, &rendered);
    if (partial and !o.lenient) {
        try err.writeAll("goldsrc-demo-tools: parts of the demo could not be read, nothing written (--lenient writes anyway)\n");
        return .partial;
    }
    if (track_list.len == 0) {
        // Nobody spoke: nothing to write, and nothing went wrong.
        try err.print("note: no voice in {s}, nothing written\n", .{o.demo});
        return if (partial) .partial else .ok;
    }

    const out_path = if (o.out) |p| try gpa.dupe(u8, p) else try defaultOutput(gpa, o.demo);
    defer gpa.free(out_path);
    writeFile(gpa, io, out_path, stem(o.demo), @as(f64, @floatFromInt(len)) * 1000 / timeline.sample_rate, encoded.items) catch |e| {
        try err.print("goldsrc-demo-tools: {s}: {t}\n", .{ out_path, e });
        return .err;
    };
    for (track_list) |t| try out.print("{s}\n", .{t.title});
    try out.print("-> {s}\n", .{out_path});
    return if (partial) .partial else .ok;
}

/// Writes the .mka through a temporary file renamed into place, so a failed
/// run never leaves a half-written file under the final name.
fn writeFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, title: []const u8, duration_ms: f64, tracks: []const mka.EncodedTrack) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    try mka.write(gpa, &fw.interface, title, duration_ms, tracks);
    try fw.interface.flush();
    try af.replace(io);
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    const code = run(init.gpa, init.io, args[1..], &out.interface, &err.interface) catch |e| blk: {
        err.interface.print("goldsrc-demo-tools: {t}\n", .{e}) catch {};
        break :blk Exit.err;
    };
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    return @backingInt(code);
}

test {
    // Pull in every file's tests.
    std.testing.refAllDecls(@This());
    _ = @import("testdata.zig");
    _ = @import("bits.zig");
    _ = @import("demo.zig");
    _ = @import("delta.zig");
    _ = @import("usermsg.zig");
    _ = @import("messages.zig");
    _ = @import("players.zig");
    _ = @import("steamvoice.zig");
    _ = @import("opus.zig");
    _ = @import("timeline.zig");
    _ = @import("mka.zig");
    _ = @import("dump.zig");
    _ = @import("info.zig");
}

const testing = std.testing;
const testdata = @import("testdata.zig");

test "parseVoiceArgs" {
    const o = parseVoiceArgs(&.{ "x.dem", "-o", "y.mka", "--tracks", "team", "--order", "team", "--lenient" }).?;
    try testing.expectEqualStrings("x.dem", o.demo);
    try testing.expectEqualStrings("y.mka", o.out.?);
    try testing.expectEqual(players.TrackMode.team, o.tracks);
    try testing.expectEqual(players.Order.team, o.order);
    try testing.expect(o.lenient and !o.dump);
    try testing.expect(parseVoiceArgs(&.{"x.dem"}).?.tracks == .player);
    for ([_][]const []const u8{ &.{}, &.{"-h"}, &.{ "a", "b" }, &.{ "a", "-o" }, &.{ "a", "--tracks", "x" }, &.{ "a", "--order" }, &.{ "a", "--bogus" } }) |bad|
        try testing.expectEqual(@as(?VoiceOptions, null), parseVoiceArgs(bad));
}

test "defaultOutput and stem" {
    const gpa = testing.allocator;
    for ([_][2][]const u8{
        .{ "demo.dem", "demo.mka" },
        .{ "/a/b.c/hltv-1.dem", "/a/b.c/hltv-1.mka" },
        .{ "noext", "noext.mka" },
        .{ "dir.x/noext", "dir.x/noext.mka" },
        .{ ".hidden", ".hidden.mka" },
    }) |c| {
        const got = try defaultOutput(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    try testing.expectEqualStrings("hltv-1", stem("/x/hltv-1.dem"));
}

/// Runs the CLI in a temp dir on a copy of a test demo.
const CliRun = struct {
    code: Exit,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn deinit(r: *CliRun) void {
        r.out.deinit();
        r.err.deinit();
    }
};

fn cli(gpa: std.mem.Allocator, args: []const []const u8) !CliRun {
    var r: CliRun = .{ .code = .ok, .out = .init(gpa), .err = .init(gpa) };
    errdefer r.deinit();
    r.code = try run(gpa, testing.io, args, &r.out.writer, &r.err.writer);
    return r;
}

fn fixturePath(buf: []u8, base: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}.dem", .{ testdata.dir, base });
}

test "cli: usage and missing files" {
    const gpa = testing.allocator;
    var r = try cli(gpa, &.{});
    defer r.deinit();
    try testing.expectEqual(Exit.usage, r.code);
    for ([_][]const []const u8{ &.{"x.dem"}, &.{"bogus"}, &.{ "bogus", "x.dem" }, &.{"voice"} }) |bad| {
        var b = try cli(gpa, bad);
        defer b.deinit();
        try testing.expectEqual(Exit.usage, b.code);
    }
    var r2 = try cli(gpa, &.{ "voice", "/nonexistent/x.dem" });
    defer r2.deinit();
    try testing.expectEqual(Exit.err, r2.code);
}

test "cli: writes a .mka the reference way, and --dump writes nothing" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [512]u8 = undefined;
    const demo_path = try fixturePath(&path_buf, "rejoin-team-switch");
    var out_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&out_buf, ".zig-cache/tmp/{s}/out.mka", .{tmp.sub_path});

    var d = try cli(gpa, &.{ "voice", demo_path, "--dump", "-o", tmp_path });
    defer d.deinit();
    try testing.expectEqual(Exit.ok, d.code);
    try testing.expect(std.mem.startsWith(u8, d.out.written(), "codec: \"(no svc_voiceinit)\", duration 211.1s\nT     nnra "));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "out.mka", .{}));

    var r = try cli(gpa, &.{ "voice", demo_path, "--order", "team", "-o", tmp_path });
    defer r.deinit();
    try testing.expectEqual(Exit.ok, r.code);
    try testing.expectEqualStrings("", r.err.written());
    const want_out = try std.fmt.allocPrint(gpa, "nnra\n-> {s}\n", .{tmp_path});
    defer gpa.free(want_out);
    try testing.expectEqualStrings(want_out, r.out.written());
    try tmp.dir.access(testing.io, "out.mka", .{});
}

test "cli: no voice exits 0 and writes nothing; the cut-off last frame is only a warning" {
    const gpa = testing.allocator;
    var path_buf: [512]u8 = undefined;
    var r = try cli(gpa, &.{ "voice", try fixturePath(&path_buf, "truncated-no-directory") });
    defer r.deinit();
    try testing.expectEqual(Exit.ok, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "note: no directory") != null);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "warning: the file ends inside a frame") != null);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "no voice in") != null);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "error:") == null);
}

test "cli: a corrupt frame makes the run partial; --lenient writes anyway" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // one-player.dem with one byte of a game frame's messages broken.
    const data = try testdata.readFixture(gpa, "one-player", ".dem");
    defer gpa.free(data);
    var it = (try demo.Demo.open(data)).frames();
    var target: ?demo.Frame = null;
    while (it.next()) |f| {
        if (f.entry == 1 and f.type.isNetwork() and f.data.len > 10) {
            target = f;
            break;
        }
    }
    const f = target.?;
    const at = @intFromPtr(f.data.ptr) - @intFromPtr(data.ptr);
    data[at] = 0; // svc_bad as the first message
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.dem", .data = data });

    var path_buf: [512]u8 = undefined;
    const bad_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/bad.dem", .{tmp.sub_path});
    var r = try cli(gpa, &.{ "voice", bad_path });
    defer r.deinit();
    try testing.expectEqual(Exit.partial, r.code);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "svc_bad (id 0) at byte 0") != null);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "nothing written") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "bad.mka", .{}));

    var l = try cli(gpa, &.{ "voice", bad_path, "--lenient" });
    defer l.deinit();
    try testing.expectEqual(Exit.partial, l.code);
    try tmp.dir.access(testing.io, "bad.mka", .{});
}

test "cli: info" {
    const gpa = testing.allocator;
    var path_buf: [512]u8 = undefined;
    var r = try cli(gpa, &.{ "info", try fixturePath(&path_buf, "one-player") });
    defer r.deinit();
    try testing.expectEqual(Exit.ok, r.code);
    try testing.expectEqualStrings(
        \\map de_dust2
        \\duration 85.623
        \\directory ok
        \\end complete
        \\players 1
        \\unidentified 0
        \\player 76561199487820327 nnra
        \\
    , r.out.written());

    var t = try cli(gpa, &.{ "info", try fixturePath(&path_buf, "truncated-no-directory") });
    defer t.deinit();
    try testing.expectEqual(Exit.ok, t.code);
    try testing.expect(std.mem.indexOf(u8, t.out.written(), "directory missing\nend cut-off\n") != null);

    var u = try cli(gpa, &.{ "info", "-x" });
    defer u.deinit();
    try testing.expectEqual(Exit.usage, u.code);
}
