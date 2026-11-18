//! Test helper: loads fixtures from testdata/ (see testdata/README.md).
//! The directory comes from build options, so tests work from any working
//! directory. Only for tests.

const std = @import("std");
const build_options = @import("build_options");

/// Absolute (or build-root relative) path of testdata/, set by build.zig.
pub const dir: []const u8 = build_options.testdata_dir;

/// The test demos, by base name (`<name>.dem`, `<name>.golden.tsv`, ...).
pub const demos = [_][]const u8{
    "one-player",
    "rejoin-team-switch",
    "truncated-no-directory",
};

/// Largest fixture we are willing to load.
const max_size = 64 * 1024 * 1024;

/// Reads `testdata/<name>` whole. Caller frees with `gpa`.
pub fn read(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.testing.io;
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    return d.readFileAlloc(io, name, gpa, .limited(max_size));
}

/// Reads `testdata/<base><ext>`, e.g. `readFixture(gpa, "one-player", ".dem")`.
pub fn readFixture(gpa: std.mem.Allocator, base: []const u8, ext: []const u8) ![]u8 {
    var name_buf: [256]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}{s}", .{ base, ext });
    return read(gpa, name);
}

/// Iterates the rows of a TSV file, skipping empty lines and `#` comments.
/// Each row is split into fields on tabs; fields borrow from the input.
pub const TsvIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    fields: [max_fields][]const u8 = undefined,

    pub const max_fields = 16;

    pub fn init(text: []const u8) TsvIterator {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// Next row's fields, or null at the end. Valid until the next call.
    pub fn next(it: *TsvIterator) error{TooManyFields}!?[]const []const u8 {
        while (it.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            var n: usize = 0;
            var fields = std.mem.splitScalar(u8, line, '\t');
            while (fields.next()) |f| {
                if (n == max_fields) return error.TooManyFields;
                it.fields[n] = f;
                n += 1;
            }
            return it.fields[0..n];
        }
        return null;
    }
};

test "every fixture loads" {
    const gpa = std.testing.allocator;
    for (demos) |base| {
        for ([_][]const u8{ ".dem", ".golden.tsv", ".messages.tsv" }) |ext| {
            const bytes = try readFixture(gpa, base, ext);
            defer gpa.free(bytes);
            try std.testing.expect(bytes.len > 0);
        }
    }
}

test "demos start with the HLDEMO magic" {
    const gpa = std.testing.allocator;
    for (demos) |base| {
        const bytes = try readFixture(gpa, base, ".dem");
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, "HLDEMO\x00\x00", bytes[0..8]);
    }
}

test "golden.tsv rows have the documented column counts" {
    const gpa = std.testing.allocator;
    var voice: usize = 0;
    for (demos) |base| {
        const text = try readFixture(gpa, base, ".golden.tsv");
        defer gpa.free(text);
        var it: TsvIterator = .init(text);
        while (try it.next()) |row| {
            const kind = row[0];
            const want: usize = if (std.mem.eql(u8, kind, "voice"))
                7
            else if (std.mem.eql(u8, kind, "voiceinit"))
                6
            else if (std.mem.eql(u8, kind, "userinfo") or std.mem.eql(u8, kind, "teaminfo"))
                6
            else
                return error.UnknownGoldenKind;
            try std.testing.expectEqual(want, row.len);
            if (std.mem.eql(u8, kind, "voice")) voice += 1;
        }
    }
    // 426 voice packets across the test demos (doc/FORMAT.md).
    try std.testing.expectEqual(@as(usize, 426), voice);
}

test "TsvIterator skips comments and blank lines" {
    var it: TsvIterator = .init("# c\nstart\tend\n\n1\t2\r\n");
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("start", a[0]);
    try std.testing.expectEqualStrings("end", a[1]);
    const b = (try it.next()).?;
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqualStrings("2", b[1]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), try it.next());
}
