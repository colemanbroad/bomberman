# Building Bomberman on Windows

Untested on Windows: the game is built and tested on macOS. Hosting should work; joining as a client uses
goose-http's WebSocket client, which that package still lists as partial on Windows.

## One-time setup (Windows 10/11 x64)

1. **Goose**: unpack `goose-v2026.3-windows-x64.zip` from https://github.com/aardappel/goose/releases/tag/v2026.3
   and add its folder to `PATH`.
2. **Visual Studio Build Tools** with the "Desktop development with C++" workload (gives the C compiler and CMake).
3. **Git** (Goose fetches its packages with it).
4. **OpenSSL via vcpkg**:
   ```
   git clone https://github.com/microsoft/vcpkg && vcpkg\bootstrap-vcpkg.bat
   vcpkg\vcpkg install openssl:x64-windows
   set VCPKG_ROOT=%CD%\vcpkg
   ```

## Build

Open "x64 Native Tools Command Prompt for VS", `cd` into this folder (`windows\`), set `VCPKG_ROOT` (or `OPENSSL_ROOT_DIR`), then:

```
build-windows.bat
```

The first build downloads three Goose packages. The result is `dist\bomberman.exe` in the repo root plus OpenSSL's DLLs; keep them together.

## Play

```
dist\bomberman.exe host                 (this PC hosts; allow it through Windows Firewall on port 8080)
dist\bomberman.exe join 192.168.4.46    (another PC or Mac joins the host's IP)
dist\bomberman.exe                      (solo)
```

Arrows or WASD move, Space drops a bomb, Escape quits. A Mac build can join a Windows host and the other way
round: the protocol is the same.
