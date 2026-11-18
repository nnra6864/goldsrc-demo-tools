//! goldsrc-hltv-voice: writes the voice chat of a GoldSrc demo to a .mka.

const std = @import("std");
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("goldsrc-hltv-voice: not implemented yet (libopus {s})\n", .{c.opus_get_version_string()});
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
}

test "libopus links" {
    const version = std.mem.span(c.opus_get_version_string());
    try std.testing.expect(std.mem.startsWith(u8, version, "libopus"));
}
