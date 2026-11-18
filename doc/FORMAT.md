# Formats

What is known about the formats involved. **Verified** means checked against real demos in `testdata/` and the reference sources. Everything else: check in ReHLTV (`doc/generated/ref/rehlds/rehlds/HLTV/`) before relying on it, and mark it verified here once a test proves it.

All integers are little-endian.

## Demo container (verified, ReHLTV `common/DemoFile.cpp`, `DemoFile.h`)

### Header, 544 bytes at offset 0

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `"HLDEMO\0\0"` |
| 8 | 4 | demo protocol, i32, 5 |
| 12 | 4 | net protocol, i32, 48 |
| 16 | 260 | map name, NUL-padded |
| 276 | 260 | game dir (`cstrike`), NUL-padded |
| 536 | 4 | map CRC, u32 |
| 540 | 4 | directory offset, i32 |

**Directory offset 0 means no directory**: HLTV was killed or the server crashed before closing the file (`testdata/truncated-no-directory.dem`). Then read frames from offset 544 until the end of the file; the last frame may be cut off.

### Directory

At the directory offset: entry count (i32, 1..1024), then entries of 92 bytes:

| Size | Field |
|---|---|
| 4 | type, i32: 0 = startup (signon), 1 = normal (game) |
| 64 | description (`"LOADING"`, `"Playback"`) |
| 4 | flags |
| 4 | CD track |
| 4 | track time, f32 |
| 4 | frame count, i32 |
| 4 | offset of the entry's frames, i32 |
| 4 | length in bytes, i32 |

HLTV demos have 2 entries: startup then normal. The entries are contiguous (`startup.offset + startup.length == normal.offset`) and the directory follows the last one. **The frame count is not the number of frames**: in HLTV demos it counts network frames only (entry 0: 0, entry 1: the number of type 1 frames). Read each entry's frames until its next-section frame (type 5) instead, as the `dem` crate does (verified on the test demos).

A directory ReHLTV can't use (entry count not in 1..1024) makes it read frames right after the header instead, as if there were no directory. We do the same for any unusable directory (offset or entries outside the file) and warn.

### Frames

Each frame: `type u8, time f32, frame i32`, then by type:

| Type | Name | Payload |
|---|---|---|
| 0, 1 | network message (0 = startup, 1 = normal) | demo info (436 bytes), sequence info (7 x i32 = 28 bytes), length i32, then `length` bytes of net messages |
| 2 | start time | nothing |
| 3 | console command | 64 bytes |
| 4 | client data | 32 bytes (origin, viewangles, weapon bits, fov) |
| 5 | next section | nothing: the entry ends here |
| 6 | event | 84 bytes (flags, index, delay, event_args 72 bytes) |
| 7 | weapon anim | 8 bytes |
| 8 | sound | channel i32, sample length i32, sample name, then attenuation f32, volume f32, flags i32, pitch i32 |
| 9 | demo buffer | length i32, then `length` bytes |

Any other type value (10..255) is read as a network frame, like types 0 and 1: `DemoFile::ReadDemoPacket` (its `default:` case) and the `dem` crate both do that. We do too and count them, since in practice it is more likely corruption. The frame's `time` is the demo time in seconds, the timeline for voice. The demo info is 436 bytes (`demo_info_t`), so the message length is at 9 + 436 + 28 bytes into a network frame (verified: walking the test demos with these sizes lands exactly on the directory offset). The length is at most 65536 (`MAX_POSSIBLE_MSG`); larger or negative is corrupt.

## Net messages (ReHLTV `Core/src/Server.cpp`)

A network message frame's data is a sequence of messages: `u8 id`, then the message. No lengths, so every message must be parsed to find the next. The table of ids and parse functions is `Server::m_ClientFuncs` at the top of `Server.cpp`; each `Server::ParseXxx` shows exactly what to read.

- ids 0..58 are engine messages (`svc_bad` 0 ... `svc_exec` 58). Protocol 48. The ids we need: `svc_updateuserinfo` 13, `svc_newusermsg` 39, `svc_voiceinit` 52, `svc_voicedata` 53.
- ids >= 64 are **user messages** (mod-defined: `TeamInfo`, `ScoreInfo`, ...). Their size comes from the matching `svc_newusermsg` (index, size, 16-byte name). Size 255 (-1) means variable: a `u8` length follows the id.
- Some messages switch to bit-level reading (delta-compressed): `svc_deltadescription`, `svc_clientdata`, `svc_packetentities`, `svc_deltapacketentities`, `svc_spawnbaseline`, `svc_event`, `svc_event_reliable`, plus `svc_sound` and some others use bit fields too. After a bit-level message the reader realigns to the next byte; check where ReHLTV does that.
- `svc_temp_entity` has a size per temp entity type: see `ParseTempEntity`.
- Message counts per test demo are in `testdata/*.messages.tsv` (from the `dem` crate): your parser must see the same numbers.

### The ones we use (verified on the test demos)

- `svc_voicedata` 53: `u8 slot` (0-based client index), `u16 length`, `length` bytes of voice. The sender's slot.
- `svc_updateuserinfo` 13: `u8 slot`, `u32 user id`, NUL-terminated info string, 16 bytes CD key hash. Info string: `\key\value\key\value...`. Keys seen: `name`, `*sid` (SteamID64 in decimal), `*hltv` (present on HLTV itself), `model`, `rate`, `cl_updaterate`, ... An empty info string means the slot was freed.
- `svc_voiceinit` 52: NUL-terminated codec name, `i8` quality. ReHLDS sends codec `""` (Steam voice). **Not present in our HLTV test demos**: don't depend on it.
- `TeamInfo` (user message): `u8 entity index` (slot + 1), NUL-terminated team name: `TERRORIST`, `CT`, `UNASSIGNED`, `SPECTATOR`. Entity indexes above maxplayers (34, 35 in our demos) are team entities, ignore them.

## Delta compression (ReHLTV `Core/src/Delta.cpp`)

`svc_deltadescription` sends a delta table (name, field count, then each field's description, itself delta-encoded against the built-in `delta_description_t` meta table). Tables seen in our demos: 7 of them (`entity_state_t`, `entity_state_player_t`, `custom_entity_state_t`, `clientdata_t`, `weapon_data_t`, `event_t`, `usercmd_t`; check names).

A delta-encoded value: a bit count of mask bytes (3 bits), the mask bytes, then for each field whose bit is set its value, read by type (`DT_BYTE`, `DT_SHORT`, `DT_FLOAT`, `DT_INTEGER`, `DT_ANGLE`, `DT_TIMEWINDOW_8`, `DT_TIMEWINDOW_BIG`, `DT_STRING`, signed flag), with the field's bit count and divisor. All of this is in `Delta.cpp` (`DELTA_ParseDelta`, `DELTA_ParseOneField`). We only need to skip values correctly, not keep them, except where a message needs a value to continue (packet entities: entity numbers, custom/player flags choose the table).

## Steam voice (verified on the test demos, 2026-11-18)

The `svc_voicedata` payload from Steam clients:

```
u64 SteamID64 (individual accounts start with 0x0110_0001 in the top 32 bits)
chunks until the last 4 bytes:
  0x0B u16          sample rate (24000 in every packet so far)
  0x0A u16          unknown, skip
  0x00 u16          silence, number of samples
  0x04 u16 len, ... SILK (never seen)
  0x06 u16 len, ... Opus PLC: frames of (u16 len, u16 seq, len bytes of Opus)
                    len 0xFFFF = reset the decoder (no seq or data follows)
u32 CRC32 (standard, poly 0xEDB88320) of everything before it
```

Opus frames are 20 ms (480 samples at 24 kHz), mono. Sequence numbers count frames and continue across packets; a gap means lost frames (conceal a few with PLC), a jump backwards means a new stream (reset). Observed on the 426 packets of the test demos: CRC ok on all, sample rate always 24000, 18 to 1308 bytes. Chunks seen: 0x0B 433 times (some packets carry it twice), 0x06 414, 0x00 (silence) 19; never 0x04 or 0x0A. Opus frames per packet: 2 (179 packets), 3 (205), 7 (26), 0 (4, silence only). Decode chunks in order, and handle a packet with only silence.

Packets only exist while someone transmits. With an open mic, Steam's voice activity detection sends nothing during silence, so bursts are separated by gaps.

## Matroska output

Minimal Matroska is enough: EBML header (DocType `matroska`), Segment with Info (TimecodeScale 1 ms, Duration, Title), Tracks (per track: TrackNumber, TrackUID, TrackType audio, CodecID `A_OPUS`, CodecPrivate = the 19-byte OpusHead, CodecDelay, SeekPreRoll 80 ms, Name, Audio: SamplingFrequency 48000, Channels 1), Tags (STEAMID per track), and Clusters with SimpleBlocks. Encode at 48 kHz (resample 24 kHz x2, or tell libopus the input is 24 kHz: an Opus encoder accepts 24 kHz input directly and the stream still decodes at 48 kHz, check `opus_encoder_create`). Verify the result with `ffprobe` and by decoding it with `ffmpeg -f null`.
