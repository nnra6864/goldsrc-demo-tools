# TODO

In order. One item at a time: implement, test, commit, tick it here with the date. Read `AGENTS.md` and `DESIGN.md` first.

## 0. Setup

- [x] Run `./fetch-docs.sh` (Zig langref, ReHLDS/ReHLTV at the pinned commit, the `dem` crate source) (2026-11-18)
- [x] `build.zig`: exe `goldsrc-hltv-voice` from `src/main.zig`, links libc + libopus, `zig build test` runs every file's tests, `zig build run -- args` (2026-11-18)
- [x] A test helper that loads `testdata/*.dem` and `*.golden.tsv` (path relative to the build root) (2026-11-18)

## 1. Demo container (`bits.zig`, `demo.zig`)

- [x] Byte reader: bounds-checked, little-endian ints and floats, fixed-size and NUL-terminated strings (2026-11-18)
- [x] Header and directory (2026-11-18)
- [x] Frame iterator over every frame type (`doc/FORMAT.md`), yielding time, entry, frame index, and the raw net message bytes of network frames (2026-11-18)
- [x] No directory (offset 0): scan from offset 544 to EOF; a cut-off last frame ends the scan with a warning, not an error (2026-11-18)
- [x] Tests: all three test demos iterate to the end; network frame counts are consistent with `*.messages.tsv` (`SvcTime` appears once per network frame in HLTV demos, check that) (2026-11-18)

## 2. Messages (`bits.zig` bit reader, `delta.zig`, `messages.zig`, `usermsg.zig`)

The core. Port each `Server::ParseXxx` from ReHLTV `Core/src/Server.cpp` and the decoding from `Core/src/Delta.cpp`. Keep only what we need; skip the rest correctly.

- [x] Bit reader (ReHLTV `common/BitBuffer.cpp`): bits LSB first, signed bit values, bit-level strings, coords/angles if a message needs them, realigning to a byte (2026-11-18)
- [x] Delta: the built-in meta description, `svc_deltadescription`, parsing (skipping) a delta-encoded value with a table (2026-11-18)
- [x] Every engine message 0..59 (svc_exec is 59), each with a unit test where a hand-built byte string is enough (2026-11-18)
- [x] User messages: table from `svc_newusermsg`, fixed and variable sizes (2026-11-18)
- [x] Per-frame error isolation: a failure stops that frame only, and is recorded (entry, frame, time, offset in the frame, message id, last message ids before it) (2026-11-18)
- [x] Tests: the three test demos parse with **zero** failed frames; find the extra `SvcTime` in `truncated-no-directory.dem` (one more than type 1 frames, see `demo.zig` tests: it's the startup frame's, and finalized demos' last frame has none); message counts equal `*.messages.tsv`; `voice`, `userinfo`, `voiceinit`, `teaminfo` events equal `*.golden.tsv` exactly (2026-11-18)

## 3. Players (`players.zig`)

- [x] Slots and identities by SteamID, rejoin, rename, HLTV skipped, placeholder for unknown slots (2026-11-18)
- [x] Starting team from `TeamInfo` (2026-11-18)
- [x] Join order and team order (2026-11-18)
- [x] Tests: `rejoin-team-switch.dem` gives one player `nnra`, SteamID 76561199487820327, starting team T, 379 packets; `one-player.dem` gives CT, 47 packets; `truncated-no-directory.dem` gives no speakers (2026-11-18)

## 4. Audio (`steamvoice.zig`, `opus.zig`, `timeline.zig`)

- [x] Steam voice packets: chunks, CRC, errors for truncated or unknown (2026-11-18; bad CRC: decode and warn, owner's call)
- [x] libopus decoder wrapper, per player, PLC for gaps up to 10 frames, reset on 0xFFFF or backwards sequence (2026-11-18)
- [x] Timeline: place at frame time, push back on overlap, `--tracks` merging (2026-11-18)
- [x] Tests: decoded sample counts per packet; speech intervals match `testdata/*.speech.tsv` (from the Rust tool's output) within 20 ms (2026-11-18)

## 5. Output (`mka.zig`)

- [x] EBML writer, Matroska with one Opus track per output track, track names, STEAMID tags, duration (2026-11-18)
- [x] libopus encoder, 48 kb/s mono (2026-11-18)
- [x] Tests: `ffprobe` reads track count, names, tags, duration; `ffmpeg -v error -i out.mka -f null -` reports nothing (only if ffmpeg is installed; skip otherwise) (2026-11-18)

## 6. CLI (`main.zig`, `dump.zig`)

- [x] Flags and exit codes as in `DESIGN.md`, `--dump`, `--lenient` (2026-11-18)
- [x] Same results as the Rust tool on every demo in `/tank/media/Replays/Counter-Strike_1.6/` (read only) (2026-11-18: `--dump` output and exit code byte-identical on all 7, including a 15.8 h, 561 MB demo still being recorded: 0.5 s vs 4.2 s)
- [x] (Low priority, owner: recording will restart each map, so very long demos shouldn't happen) Memory for long demos: a timeline is dense f32 PCM, about 345 MB per track per hour (the 15.8 h demo above would need 5.4 GB per track if anyone spoke). Render and encode in time chunks, or keep only the stretches with voice and encode silence frames directly (2026-11-18: rendered and encoded in 60 s chunks, `.mka` byte-identical on every test and archive demo; what stays in memory is the encoded track, silence is 3-byte packets, about 1.3 MB per track per hour)
- [ ] (Low priority) Encoding speed: libopus at default complexity costs about 8.6 ms CPU per second of audio per track, mostly encoding silence (1.8 s for the 212 s `rejoin-team-switch.dem`, so about 31 s per track per hour). Options: emit a fixed silence packet for all-zero frames once the encoder is idle, or lower the complexity. Either changes the output bytes, so check speech timing against `testdata/*.speech.tsv` again

## 7. Then

- [x] In the server container (`~/Containers/counter-strike`): build in a stage, run after each map when HLTV closes the demo, `--order` per server (regular `join`, competitive `team`). The owner deploys; agents only prepare the change (2026-11-18: counter-strike-podman `0b165b5`, not pushed or deployed; `voice.sh`, `ENABLE_VOICE_MKA`, `VOICE_MKA_ARGS`; libopus 1.6.1 built from source since bookworm's 1.3.1 fails the speech test)
- [x] Forgejo repo, README usage (2026-11-18)
- [x] Retire the Rust prototype (2026-11-18: counter-strike-podman `6f960f2`; the reference is now `138a934`)

## 8. Demo tools (owner, 2026-11-19: a full replacement, more than voice)

- [x] Rename to goldsrc-demo-tools, subcommands; `voice` is the old CLI (2026-11-19)
- [x] `info`: map, duration, directory, end, players who joined (HLTV skipped; without a SteamID counted apart), `key value` lines, so the server can delete demos nobody joined (2026-11-19; 4 of the 9 archive demos had nobody, one of them 16.6 h)
- [x] `repair`: finish a demo cut off by a crash or kill (drop a cut-off last frame, write the last frame and the directory) so the game plays it (2026-11-19: byte-identical to HLTV on the test demos; the 6 unfinished archive demos repair, read the same in our parser and the Rust prototype, and ReHLTV `playdemo` reads their directory without the "bogus" warning)
- [ ] Server container: stop cleanly (HLTV `stoprecording` before shutdown), record only while players are on (`hltv_tools` plugin reports the count), repair leftovers, delete demos nobody joined
