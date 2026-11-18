# Zig 0.17 notes

Gotchas found while working on this project. Add one whenever something about Zig 0.17 surprised you, with the fix, so the next agent doesn't repeat it. Check the std source (`/home/nn/.zvm/0.17.1/lib/std/`) before trusting memory of older Zig.

## Build system

- **`@cImport` is gone.** C headers go through `b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target, .optimize })`, then `module.addImport("c", translate_c.createModule())`, and `@import("c")` in code. The first translate-c of libopus takes about a minute; it is cached after that.
- **Run args:** `run_cmd.addPassthruArgs()`, not `if (b.args) |args| run_cmd.addArgs(args)`.
- **`b.build_root` / `b.pathFromRoot` don't exist** (the `Build` struct has `root: Cache.Path`). To give code a path to a source directory, use build options: `options.addOptionPathDirectory("testdata_dir", b.path("testdata"))`, `module.addOptions("build_options", options)`, then `@import("build_options").testdata_dir`. It also makes tests rebuild when the directory changes.
- `b.addExecutable` / `b.addTest` take a `.root_module` (from `b.createModule`); `link_libc` is a module option, `module.linkSystemLibrary("opus", .{})` links a system library.

## Runtime

- `main` takes `init: std.process.Init` (has `.io`, `.gpa`, `.arena`, `.minimal.args`).
- Tests get an `Io` from `std.testing.io`.

## Language

- **`**` (array repetition) is gone.** `[_]u8{0} ** n` fails with "binary operator '*' has whitespace on one side". Use `var a: [n]u8 = @splat(0);`, or `@as([n]u8, @splat(0))` inside an expression. `++` still works, but an anonymous `&.{ 1, 2 } ++ x` doesn't: write `&([_]u8{ 1, 2 } ++ x)`.
- `@cImport` is gone too (see Build system).
- **`@intFromEnum` is now `@backingInt`** (also works on packed structs and tagged unions). `zig fmt` rewrites old calls silently, so a script that edits source by matching `@intFromEnum(...)` text after formatting won't match. Likewise `@enumFromInt` became `@fromBackingInt`.
- `**` doesn't work on string literals either. For comptime repetition in tests: `inline fn rep(comptime c: u8, comptime n: usize) *const [n]u8 { comptime { const a: [n]u8 = @splat(c); return &a; } }`, then `"x" ++ rep(0, 16)`.
