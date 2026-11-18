# TODO

Port of `~/Containers/counter-strike/tools/demo-voice` (Rust, working). Keep it as the reference until this matches it.

## Port

- [ ] Demo file: header, directory, frames (`demo_parser.rs` in the `dem` crate is the reference)
- [ ] Net messages. svc messages carry no length, so every one up to `svc_voicedata` has to be parsed, including delta-compressed ones (`svc_deltadescription`, `svc_packetentities`, `svc_deltapacketentities`, `svc_clientdata`, `svc_event`, ...). User messages: sizes from `svc_newusermsg`
- [ ] Players: `svc_updateuserinfo` (`*sid`, `name`, skip `*hltv`), `TeamInfo` for the starting team
- [ ] Steam voice: SteamID, 0x0B sample rate, 0x00 silence, 0x06 Opus PLC (u16 len, u16 seq, frame; 0xFFFF resets), CRC32. 24 kHz in practice
- [ ] Decode with libopus (C import), one decoder per player, conceal short losses
- [ ] Write the `.mka` directly (EBML + Opus encoded with libopus), no ffmpeg, so it can run inside the server container
- [ ] Same CLI and output as the Rust version, checked against the test demos in `/tank/media/Replays/Counter-Strike_1.6/Competitive`

## Then

- [ ] Server container: build it in a stage and run it after each map (HLTV closes the file on map change). `--order` per server: regular `join`, competitive `team`
- [ ] Forgejo repo
