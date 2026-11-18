# AGENTS.md

Instructions for AI coding agents working on goldsrc-hltv-voice. Read this, then `DESIGN.md`, then `TODO.md` (your task list), before writing code.

---

## Project settings (edit me)

- **Name:** goldsrc-hltv-voice. Binary, package and repo use that name; the Zig package/namespace is `goldsrc_hltv_voice`.
- **Language / version:** Zig 0.17.1 (tagged release), pinned with `minimum_zig_version` in `build.zig.zon`. Never target Zig master.
- **System dependency:** libopus (C, linked with `linkSystemLibrary("opus")`). Nothing else without asking.
- **Platform:** Linux. It must also build for the CS server container (Debian bookworm, x86_64).
- **Owner:** nnra (`@nnra6864`). Git host: `git.nnstdios.com`.

---

## What this project is

A CLI that reads a GoldSrc demo (`.dem`, mainly HLTV demos from CS 1.6) and writes its voice chat as one `.mka` with an Opus track per player. It replaced a Rust prototype (`tools/demo-voice` in [counter-strike-podman](https://git.nnstdios.com/nnra6864/counter-strike-podman) at commit `138a934` (removed after it)), which is the behavioural reference. The owner cares about voice replays a lot: **never lose or corrupt voice silently**.

## Hard rules

1. **One step at a time.** Do one TODO item, test it, commit it, then the next. Tick items in `TODO.md` as you finish them, with the date.
2. **Git:** commit on `master`, small commits, conventional prefixes (`feat:`, `fix:`, `test:`, `docs:`, `chore:`, `perf:`). Never push, force, rebase published history or rewrite commits unless asked. End commit messages with the attribution line your harness gives you.
3. **Questions:** if something is the owner's call (behaviour, naming, output format, a new dependency), write it in `QUESTIONS.md` and carry on with something else. Don't guess on those.
4. **Dependencies:** none beyond Zig std and libopus without asking (rule 3).
5. **Never modify the test fixtures** in `testdata/` (`.dem`, `.golden.tsv`, `.messages.tsv`, `.mka`). They come from real recordings and from the reference tool. If one looks wrong, ask.
6. **Never touch the owner's servers or files** outside this repo: `~/Containers/**`, `/tank/**`. Reading `/tank/media/Replays/Counter-Strike_1.6/**` demos for extra testing is fine; writing there is not.
7. **No silent data loss.** A frame that fails to parse is counted and reported (frame index, time, message id, reason), never skipped quietly. Exit non-zero if any voice-bearing data might be lost, unless `--lenient` is given.
8. **ASCII only** in source and docs, except the README footer (keep it as is, always last in the README) and player names in test data.
9. **Tests pass before every commit:** `zig build test`. Add tests with every feature (see "What to test").

## Looking things up

- **Zig 0.17 changed a lot** (the `std.Io` interface, `Reader`/`Writer`, ArrayList being unmanaged, build system APIs). Your memory of older Zig is often wrong. Before using a std API, check it in the std source: `$(zig env | grep lib_dir)/std/` (here `/home/nn/.zvm/0.17.1/lib/std/`). The language reference is in `doc/generated/zig/langref.html` after `./fetch-docs.sh`.
- Write down every Zig gotcha you hit in `doc/ZIG_NOTES.md`, so the next agent doesn't hit it again.
- **Format references** (fetched by `./fetch-docs.sh` into `doc/generated/ref/`, pinned commits):
  - ReHLTV (in the ReHLDS repo, `rehlds/HLTV/`): the HLTV that records these demos. **This is the spec.** `common/DemoFile.cpp` (demo container), `Core/src/Server.cpp` (every svc message), `Core/src/Delta.cpp` (delta decoding), `common/BitBuffer.cpp` (bit reading).
  - The `dem` Rust crate 0.3.0: an independent GoldSrc demo parser. Use it as a second opinion, not as the spec.
  - The Rust prototype: `git -C ~/Containers/counter-strike show 138a934:tools/demo-voice/src/main.rs` (and `steamvoice.rs`): Steam voice, timeline, track order.
- `doc/FORMAT.md` has what is already known and verified. Add to it when you verify more.
- Large files: search them (`grep -n`) and read the parts you need, don't read 2000-line files whole.

## Zig style

- `zig fmt` everything.
- Explicit allocators passed in, no globals. Free what you allocate; tests use `std.testing.allocator` so leaks fail.
- Errors are error unions with a diagnostic struct for user-facing context (file offset, frame, time, message id). No `catch unreachable` on input data: demos come from crashes, old versions and other games.
- Parsing never reads past a buffer: bounds-checked reader, every length checked against what's left.
- Small files by concern (see `DESIGN.md` layout). `///` doc comments on public declarations.
- Clarity over speed unless a measurement says otherwise. A 10-minute demo should still parse in well under a second.

## What to test

- **Bit reader:** reads across byte boundaries, signed values, strings, reading past the end errors.
- **Delta decoding:** decoding a delta description, each field type (integer, signed, float with divisor, angle, string, timewindow), fields absent vs present, against hand-built bit strings.
- **Demo container:** header, directory, every frame type, demos without a directory (crashes: read frames from offset 544 until EOF), truncated last frame.
- **Messages:** each test demo parses with **zero** failed frames, and the count of each message type matches `testdata/*.messages.tsv`.
- **Golden voice:** every `voice`, `userinfo`, `teaminfo` and `voiceinit` line in `testdata/*.golden.tsv` is reproduced exactly (same order, frame, slot, bytes; time to 6 decimals).
- **Steam voice:** packet parsing (SteamID, chunks, CRC), bad CRC, unknown chunk, truncated packet, 0xFFFF reset, sequence gaps and wraparound.
- **Players:** rejoin in another slot continues the same track, renames, HLTV skipped, no SteamID falls back to name, starting team, `--order join|team`, `--tracks player|team|mix`.
- **Output:** the `.mka` opens in ffprobe with the right track count, names, `STEAMID` tags and duration; speech lands at the same times as in `testdata/*.mka` (within 20 ms).

## Where things are

- `DESIGN.md`: goals, architecture, behaviour, non-goals
- `TODO.md`: the plan, in order
- `QUESTIONS.md`: open questions for the owner
- `doc/FORMAT.md`: the demo, message and Steam voice formats, as verified
- `doc/ZIG_NOTES.md`: Zig 0.17 gotchas found so far
- `fetch-docs.sh`: fetches the Zig langref and the reference sources into `doc/generated/` (gitignored)
- `testdata/`: real demos plus golden outputs, see `testdata/README.md`
