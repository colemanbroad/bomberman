# Bomberman

Multiplayer Bomberman in [Goose](https://github.com/aardappel/goose): gfx/ui (Nuklear) graphics, procedural sound, and
host-authoritative online play over WebSocket ([goose-http](https://github.com/kaitk/goose-http)).

```
goose build bomberman.goose
./bomberman host                 # host a game on port 8080 and play as P1
./bomberman join HOST            # join a host, e.g. ./bomberman join 192.168.4.46
./bomberman                      # solo
```

Arrows/WASD move, Space drops a bomb (or launches/detonates a Heat-Seeker Missile, or switches afterlife forms when dead), `E`/`X` (or `Shift+Space`) drops a proximity mine, hold Shift to stand your ground (you freeze and others cannot walk through you), M mutes the music, N cycles through all built-in tracks, Escape closes menus or quits. Up to 4 players. Clients predict their own movement and the host sends a snapshot every 60 Hz tick.

- **Profiles & Win Streaks**: Click **Profile** to enter your custom name (or pass `--name NAME`) and pick your farm animal. Consecutive round wins track your win streak, and every 5 wins triggers a full-screen spotlight victory dance in everyone's faces.
- **Farm Characters & Themed Bombs**: Goose (eggs), Squirrel (acorns), Baby (diapers), Cow (cow patties), Pig (bacon), and Farmer (hay bales).
- **Maps & Music**: Choose between **Tropical Island**, **Forest**, **Mountains**, and **Desert** (each with its own visuals, layout flavor, and original procedural soundtrack; pass `--map 0..3` or change live in **Host Settings**).
- **Host Settings**: Click **Host Settings** to toggle which power-ups can spawn, switch maps, toggle portals, adjust power-up drop rate (default 33%), and tune wall/block regrowth rate when the field gets empty.
- **Power-Ups**: Flame (range+), Bomb (extra bomb), Bolt (speed+), Ghost (10 s invisibility), Kick Boot (kick bombs), Heat-Seeker Missile (stand stationary wearing a headset while steering a guided missile), Napalm (leaves a slowly decaying trail of fire behind you), Proximity Mines (`E`/`X` or `Shift+Space`), Drunk (random jitter to fight against, plus every other positive power), Curse/Bad (longer fire, slower movement), and Unkickable Bombs (anchored bombs that refuse to slide).
- **Portals & Afterlife**: Linked Cyan ↔ Orange portals teleport characters, sheep, bombs, and missiles. When eliminated in multiplayer, participate immediately as a controllable **Black Sheep** (blocks alive players & kicked bombs) or press `Space` to switch to a fast **Fog Ghost** (phases through walls and leaves thick obscuring fog).
- `build-portable.sh` (macOS) relinks OpenSSL statically and zips a binary that runs on any Apple Silicon Mac.
- `windows/` has a build script and notes for Windows (untested).
- Needs CMake and OpenSSL to build (the WebSocket client's TLS package). `Roboto-Regular.ttf` is Apache 2.0.

Your own music: put a 16-bit WAV named `music.wav` in the folder you launch the game from and it loops instead of the
chiptune (M still mutes). Convert a track you own on a Mac with
`afconvert -f WAVE -d LEI16 song.mp3 music.wav`, or anywhere with `ffmpeg -i song.mp3 -c:a pcm_s16le music.wav`.
Each player uses their own file. `music.wav` is git-ignored, so it never lands in the repo.

UDP transport is enabled by default when joining (`bomberman join HOST`; pass `tcp` to force TCP-only). The client opens a UDP socket (`udp.c`: POSIX sockets, Winsock on Windows) and sends a redundant 8-tick input ring to the host's UDP port 8080 at 60 Hz; the host steps inputs in exact `seq` order and answers with a datagram snapshot every tick. The WebSocket stays up for joining, profiles, leaving, and a 2 Hz heartbeat—and automatically carries 60 Hz snapshots if either direction of UDP is blocked. Allow UDP port 8080 through the host's firewall. The window label shows `CLIENT P2 UDP` once bidirectional UDP is confirmed; on exit each side prints how many datagrams it saw. There is no authentication: any packet naming a slot drives it, which is fine for a LAN.
