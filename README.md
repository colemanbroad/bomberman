# Bomberman

Multiplayer Bomberman in [Goose](https://github.com/aardappel/goose): gfx/ui (Nuklear) graphics, procedural sound, and
host-authoritative online play over WebSocket ([goose-http](https://github.com/kaitk/goose-http)).

```
goose build bomberman.goose
./bomberman host                 # host a game on port 8080 and play as P1
./bomberman join HOST            # join a host, e.g. ./bomberman join 192.168.4.46
./bomberman                      # solo
```

Arrows/WASD move, Space drops a bomb, Escape quits. Up to 4 players. Clients predict their own movement and
the host sends a snapshot every 60 Hz tick.

- `build-portable.sh` (macOS) relinks OpenSSL statically and zips a binary that runs on any Apple Silicon Mac.
- `windows/` has a build script and notes for Windows (untested).
- Needs CMake and OpenSSL to build (the WebSocket client's TLS package). `Roboto-Regular.ttf` is Apache 2.0.
