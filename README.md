# Bomberman

Multiplayer Bomberman in [Goose](https://github.com/aardappel/goose): gfx/ui (Nuklear) graphics, procedural sound, and
host-authoritative online play over WebSocket ([goose-http](https://github.com/kaitk/goose-http)).

```
goose build bomberman.goose
./bomberman host                 # host a game on port 8080 and play as P1
./bomberman join HOST            # join a host, e.g. ./bomberman join 192.168.4.46
./bomberman                      # solo
```

Arrows/WASD move, Space drops a bomb, hold Shift to stand your ground (you freeze and others cannot walk through you), M mutes the music, N switches between the two built-in tracks (the fun one and a dark, heavy one), Escape quits. Up to 4 players. Clients predict their own movement and
the host sends a snapshot every 60 Hz tick.

- `build-portable.sh` (macOS) relinks OpenSSL statically and zips a binary that runs on any Apple Silicon Mac.
- `windows/` has a build script and notes for Windows (untested).
- Needs CMake and OpenSSL to build (the WebSocket client's TLS package). `Roboto-Regular.ttf` is Apache 2.0.

Power-ups: flame (range), bomb (extra bomb), bolt (speed), the orange boot (kick: run into a bomb and it slides until something solid stops it), and the purple ghost (10 s): you turn invisible to
everyone else, leaving only a faint trail of dust while you move. You still see a faint outline of yourself.

Characters: player 2 is a goose, and her bombs are eggs. Two sheep wander at random and block the way like movable
blocks (flames kill them; they return next round). The host (or solo player) has a slider in the top bar for the
percentage of burned bricks that leave a power-up (default 33). Gift crates always drop one.

Your own music: put a 16-bit WAV named `music.wav` in the folder you launch the game from and it loops instead of the
chiptune (M still mutes). Convert a track you own on a Mac with
`afconvert -f WAVE -d LEI16 song.mp3 music.wav`, or anywhere with `ffmpeg -i song.mp3 -c:a pcm_s16le music.wav`.
Each player uses their own file. `music.wav` is git-ignored, so it never lands in the repo.
