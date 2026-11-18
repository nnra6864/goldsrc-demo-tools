# goldsrc-hltv-voice

Turns the voice chat in a GoldSrc demo (CS 1.6, Condition Zero, Day of Defeat, TFC, HL Deathmatch, ...) into one `.mka` with a track per player.

```sh
goldsrc-hltv-voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump]
```

- One track per player, named after them, with their SteamID as a tag. Players are keyed by SteamID, so a rejoin, even in another slot, continues the same track
- `--order join` (default): by first join. `--order team`: by starting team, T then CT, join order within a team
- `--tracks team` or `--tracks mix`: one track per starting team, or everyone in one
- `--dump`: who spoke, and the raw voice packets

HLTV only records voices it can hear. On a CS server, a plugin that lets HLTV hear everyone (players still hear only their team) is in [counter-strike-podman](https://git.nnstdios.com/nnra6864/counter-strike-podman) (`plugins/hltv_voice.sma`).

## Status

Being ported from the Rust prototype in `counter-strike-podman/tools/demo-voice`, which works (tested 2026-11-18). See `TODO.md`.
