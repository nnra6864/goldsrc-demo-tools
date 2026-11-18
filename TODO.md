# TODO

In order. One item at a time: implement, test, commit, tick it here with the date. Read `AGENTS.md` and `DESIGN.md` first.

## 0. Setup

- [x] Run `./fetch-docs.sh` (Zig langref, ReHLDS/ReHLTV at the pinned commit, the `dem` crate source) (2026-11-18)
- [x] `build.zig`: exe `goldsrc-hltv-voice` from `src/main.zig`, links libc + libopus, `zig build test` runs every file's tests, `zig build run -- args` (2026-11-18)
- [x] A test helper that loads `testdata/*.dem` and `*.golden.tsv` (path relative to the build root) (2026-11-18)

## 1. Demo container (`bits.zig`, `demo.zig`)

- [x] Byte reader: bounds-checked, little-endian ints and floats, fixed-size and NUL-terminated strings (2026-11-18)
- [ ] Header and directory
- [ ] Frame iterator over every frame type (`doc/FORMAT.md`), yielding time, entry, frame index, and the raw net message bytes of network frames
- [ ] No directory (offset 0): scan from offset 544 to EOF; a cut-off last frame ends the scan with a warning, not an error
- [ ] Tests: all three test demos iterate to the end; network frame counts are consistent with `*.messages.tsv` (`SvcTime` appears once per network frame in HLTV demos, check that)

## 2. Messages (`bits.zig` bit reader, `delta.zig`, `messages.zig`, `usermsg.zig`)

The core. Port each `Server::ParseXxx` from ReHLTV `Core/src/Server.cpp` and the decoding from `Core/src/Delta.cpp`. Keep only what we need; skip the rest correctly.

- [ ] Bit reader (ReHLTV `common/BitBuffer.cpp`): bits LSB first, signed bit values, bit-level strings, coords/angles if a message needs them, realigning to a byte
- [ ] Delta: the built-in meta description, `svc_deltadescription`, parsing (skipping) a delta-encoded value with a table
- [ ] Every engine message 0..58, each with a unit test where a hand-built byte string is enough
- [ ] User messages: table from `svc_newusermsg`, fixed and variable sizes
- [ ] Per-frame error isolation: a failure stops that frame only, and is recorded (entry, frame, time, offset in the frame, message id, last message ids before it)
- [ ] Tests: the three test demos parse with **zero** failed frames; message counts equal `*.messages.tsv`; `voice`, `userinfo`, `voiceinit`, `teaminfo` events equal `*.golden.tsv` exactly

## 3. Players (`players.zig`)

- [ ] Slots and identities by SteamID, rejoin, rename, HLTV skipped, placeholder for unknown slots
- [ ] Starting team from `TeamInfo`
- [ ] Join order and team order
- [ ] Tests: `rejoin-team-switch.dem` gives one player `nnra`, SteamID 76561199487820327, starting team T, 379 packets; `one-player.dem` gives CT, 47 packets; `truncated-no-directory.dem` gives no speakers

## 4. Audio (`steamvoice.zig`, `opus.zig`, `timeline.zig`)

- [ ] Steam voice packets: chunks, CRC, errors for truncated or unknown
- [ ] libopus decoder wrapper, per player, PLC for gaps up to 10 frames, reset on 0xFFFF or backwards sequence
- [ ] Timeline: place at frame time, push back on overlap, `--tracks` merging
- [ ] Tests: decoded sample counts per packet; speech intervals match `testdata/*.speech.tsv` (from the Rust tool's output) within 20 ms

## 5. Output (`mka.zig`)

- [ ] EBML writer, Matroska with one Opus track per output track, track names, STEAMID tags, duration
- [ ] libopus encoder, 48 kb/s mono
- [ ] Tests: `ffprobe` reads track count, names, tags, duration; `ffmpeg -v error -i out.mka -f null -` reports nothing (only if ffmpeg is installed; skip otherwise)

## 6. CLI (`main.zig`, `dump.zig`)

- [ ] Flags and exit codes as in `DESIGN.md`, `--dump`, `--lenient`
- [ ] Same results as the Rust tool on every demo in `/tank/media/Replays/Counter-Strike_1.6/` (read only)

## 7. Then (ask before starting)

- [ ] In the server container (`~/Containers/counter-strike`): build in a stage, run after each map when HLTV closes the demo, `--order` per server (regular `join`, competitive `team`). The owner deploys; agents only prepare the change
- [ ] Forgejo repo, README usage
- [ ] Retire the Rust prototype
