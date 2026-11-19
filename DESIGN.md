# Design

## Goal

`goldsrc-demo-tools voice demo.dem` writes `demo.mka`: one Opus track per player who spoke, each placed at the right time over the whole demo, so the `.mka` plays in sync with the demo from the start.

What matters, in order:

1. **No voice lost or corrupted silently.** Anything that can't be parsed is reported. A partial result says it's partial.
2. **Correct timing and identity.** Speech at the right moment, in the right player's track, across rejoins and renames.
3. **Works on any GoldSrc demo:** HLTV demos (the main use) and client demos, CS 1.6 and other mods, demos with no directory (server crash, HLTV killed).
4. **Self-contained:** one static-ish binary plus libopus. No ffmpeg, so it can run inside the server container after every map.

## Background

The CS 1.6 servers run ReHLDS with HLTV recording every map. A plugin makes HLTV hear every player, so each demo holds all voice chat as `svc_voicedata` messages: the sender's slot plus a Steam voice packet (Opus at 24 kHz). See `doc/FORMAT.md`.

GoldSrc net messages carry no length. To reach a `svc_voicedata` you have to parse every message before it in the frame, including the delta-compressed entity updates. That's most of the work, and the part to be careful with.

## CLI

```
goldsrc-demo-tools <command> <demo.dem> [options]
goldsrc-demo-tools voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump] [--lenient]
```

`info <demo.dem>` prints `key value` lines: `map`, `duration`, `directory`, `end`, `players`, `unidentified`, and a `player <steamid or -> <name>` line each. `players` counts who joined with a SteamID, `unidentified` who joined without one (bots, non-Steam clients) or spoke from a slot no userinfo named; HLTV is never counted. Exit 3 when frames failed to parse, since a lost userinfo could hide a player: a script deleting empty demos must check the exit code.

The tool replaces the Rust prototype fully (owner, 2026-11-19), including what the server needs around demos, so it has subcommands. `voice` has the prototype's flags and behaviour, plus `--lenient`; its options are below.

- `-o`: output path. Default: the demo path with `.mka`.
- `--tracks player` (default): a track per player. `team`: one per starting team (T, CT, Other). `mix`: one track.
- `--order join` (default): tracks in order of first join. `team`: by starting team (T, then CT, then the rest), join order within a team.
- `--dump`: print the codec, each player (starting team, name, SteamID, join time, packet count, first/last voice time) and their first packets, and write nothing.
- `--lenient`: write the `.mka` even if some frames failed to parse (they're still reported).
- Exit codes: 0 ok, 1 error, 2 usage, 3 partial (frames failed to parse, without `--lenient`: nothing written).
  - Partial means voice may be missing: a frame whose messages failed to parse, a corrupt frame length that ends the scan, or a voice packet that failed to decode. A cut-off last frame (crashed or killed HLTV) is only a warning. With `--lenient` the `.mka` is written and the exit code is still 3, so scripts can tell.
  - No voice at all: exit 0, nothing written, a note on stderr (owner, 2026-11-18; the Rust tool exits 1).
  - `--dump` exits 3 too when the demo is partial.
  - The `.mka` is written to a temporary file and renamed into place: never a half-written file under the final name.

## Behaviour

- **Players are identified by SteamID** (`*sid` in userinfo), falling back to `name:<name>` when there's none. A rejoin, even in another slot, continues the same track. The latest name is the track name. `*hltv` clients are skipped.
- **Slots:** `svc_updateuserinfo` with an empty userinfo frees the slot. Voice from a slot with no known player gets a placeholder player `slot N` (N = slot + 1, as in the Rust tool). An empty `name` frees the slot too, and voice packets with no data are ignored (as in the Rust tool).
- **Starting team:** the first `TeamInfo` of TERRORIST or CT for that player. Team changes later (halftime, switching) don't move the track.
- **Timeline:** each voice packet is decoded and placed at its frame's demo time. If it would overlap the previous audio of the same player, it goes right after it instead (packets arrive in bursts within one frame). Silence between bursts stays silence.
- **Bad CRC:** a Steam voice packet whose checksum doesn't match is still decoded (no voice dropped) and counted in a warning; it doesn't change the exit code (owner, 2026-11-18).
- **Decoding:** one libopus decoder per player. Sequence gaps of up to 10 frames are concealed (Opus PLC, 20 ms per lost frame), longer gaps conceal 10 frames and the rest is silence. A sequence going backwards or a 0xFFFF length resets the decoder. A packet that fails to decode is lost as a whole and reported. (The Rust tool asks libopus for 120 ms of PLC per lost frame, which stretches gaps 6x and pushes later speech back; none of the test demos has a gap, so it does not show in the fixtures.)
- **Output:** Matroska, one Opus track per output track, 48 kHz mono, about 48 kb/s, track `title` = player name, tag `STEAMID` = SteamID, segment title = demo file name. Duration = demo duration.

## Architecture

```
src/
  main.zig          CLI: args, run, exit codes
  bits.zig          bounds-checked little-endian byte and bit reader
  demo.zig          demo container: header, directory, frames (no net message knowledge)
  delta.zig         delta descriptions and delta decoding
  messages.zig      svc message parsing: walks a frame's message bytes, yields the ones we need
  usermsg.zig       user message table (svc_newusermsg) and TeamInfo
  players.zig       userinfo, slots, identities, teams, voice packets per player
  steamvoice.zig    Steam voice packet format, CRC
  opus.zig          libopus decode/encode wrapper
  timeline.zig      placing decoded audio on a per-track timeline
  mka.zig           Matroska (EBML) writer for Opus tracks
  dump.zig          --dump output
```

Layers: `bits` knows nothing else. `demo` knows only the container. `messages` and `delta` know the protocol but nothing about players or audio. `players` consumes parsed messages. Audio (`steamvoice`, `opus`, `timeline`, `mka`) never sees the demo format.

Memory: a demo is read whole into memory (they're a few MB, at most a few hundred). Decoded audio is mono f32 at 24 kHz, rendered and encoded to Opus track by track in 60 s chunks, so memory does not grow with the demo length beyond the encoded tracks (silence is 3 bytes per 20 ms).

## Non-goals

- Playing or rendering demos, or anything about entities beyond skipping them correctly.
- Writing demos, except finishing one that was cut off (`repair`).
- Codecs other than Steam voice (Opus). Old Speex/Miles (non-Steam clients) and SILK are reported as unsupported, not decoded. Might come later if a real demo needs it.
- Windows/macOS for now.
