# goldsrc-hltv-voice

Turns the voice chat in a GoldSrc demo (CS 1.6, Condition Zero, Day of Defeat, TFC, HL Deathmatch, ...) into one `.mka` with a track per player, in sync with the demo.

> [!NOTE]
> Work in progress: being written to replace a working Rust prototype. See `TODO.md`.

## Usage

```sh
goldsrc-hltv-voice <demo.dem> [-o out.mka] [--tracks player|team|mix] [--order join|team] [--dump] [--lenient]
```

- One track per player, named after them, with their SteamID as a tag. A player who rejoins, even in another slot, continues their own track
- `--order join` (default): tracks by first join. `--order team`: by starting team, T then CT, join order within a team
- `--tracks team` or `--tracks mix`: one track per starting team, or everyone in one
- `--dump`: who spoke, and their raw voice packets
- `--lenient`: write the `.mka` even if parts of the demo couldn't be read (they're reported either way)

Demos from a crashed server (no directory) work too.

## Recording voice

HLTV only records the voices it can hear, and on CS it's a spectator, so normally it hears nobody. [counter-strike-podman](https://git.nnstdios.com/nnra6864/counter-strike-podman) has a small AMX Mod X plugin (`plugins/hltv_voice.sma`) that lets HLTV hear every player while players still hear only their own team. Without it, `sv_alltalk 1` (everyone hears everyone) or `3` (spectators hear everyone) also works.

## Building

Needs Zig 0.17.1 and libopus.

```sh
zig build                 # zig-out/bin/goldsrc-hltv-voice
zig build test
```

# ☦

```
   Ὤ
 Ὁ   Ν
Ι̅Ϲ̅ │ Χ̅Ϲ̅
───┼───
ΝΙ │ ΚΑ
   ☦
```

Εἰς δόξαν τοῦ Θεοῦ<br>
*To the glory of God*

Τῇ Ὑπεραγίᾳ Θεοτόκῳ δόξα<br>
*Glory to the Most Holy Theotokos*

Δόξα τῷ Θεῷ πάντων ἕνεκεν<br>
*Glory to God for all things*

ΑΜΗΝ

☦
