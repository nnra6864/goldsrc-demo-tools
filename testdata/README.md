# Test data

Real HLTV demos from the owner's CS 1.6 server (ReHLDS 3.15, ReHLTV, ReGameDLL 5.30, Steam client), recorded 2026-11-18, plus outputs of the Rust prototype (`~/Containers/counter-strike/tools/demo-voice`, the reference). **Never edit these files** (AGENTS.md rule 5).

| Demo | What's in it |
|---|---|
| `one-player.dem` | One player (`nnra`) joins CT and talks twice, about 43-50 s |
| `rejoin-team-switch.dem` | `nnra` joins T, talks 5 times (mic open, so with silences), disconnects, reconnects into CT, talks 5 more times. One track expected, starting team T |
| `truncated-no-directory.dem` | 12 minutes, nobody talks, and **no directory** (offset 0): HLTV was killed mid-recording. Read frames from offset 544 to EOF |

Per demo:

- `*.golden.tsv`: every `voice`, `userinfo`, `teaminfo` and `voiceinit` in demo order, tab separated, from the `dem` crate (`examples/golden.rs` in the Rust tool). Columns:
  - `voice <entry> <frame> <time> <slot> <len> <hex>`
  - `userinfo <entry> <frame> <time> <slot> <infostring>`
  - `teaminfo <entry> <frame> <time> <entindex> <team>`
  - `voiceinit <entry> <frame> <time> <codec> <quality>` (none in these demos)
  - `<frame>` is the index in the entry's frame list, counting every frame type. Time has 6 decimals
- `*.messages.tsv`: count of every message type (`SvcXxx` engine messages, `user:Name` user messages), from the `dem` crate
- `*.mka`: the Rust tool's output (`--order team`)
- `*.speech.tsv`: speech intervals in that `.mka` (ffmpeg `silencedetect`, -45 dB, 0.4 s)

More demos (read only): `/tank/media/Replays/Counter-Strike_1.6/`.
