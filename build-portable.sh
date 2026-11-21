#!/bin/sh
# Builds ./bomberman-portable (OpenSSL linked statically) and bomberman-mac-arm64.zip.
set -e
cd "$(dirname "$0")"
goose build bomberman.goose
B=$HOME/.goose/build
D=$(dirname "$(ls -t $B/prog/bomberman-*/bomberman.c | head -1)")
P=$(ls -d $B/pkg/github.com/kaitk/goose-tls/*/*/link-cc.rsp | head -1)
sed 's/\.dylib/.a/' "$P" > /tmp/bomberman-tls.rsp
cc -O2 -w $D/bomberman.c $(ls -d $B/runtime/*/*-release/goose_runtime.o | head -1) -o bomberman-portable \
  @$(ls -d $B/pkg/github.com/kaitk/goose-http/*/*/link-cc.rsp | head -1) @$(ls -d $B/builtin/gfx-*/link-cc.rsp | head -1) \
  @$(ls -d $B/pkg/github.com/kaitk/goose-hash/*/*/link-cc.rsp | head -1) @$(ls -d $D/native/*/link-cc.rsp | head -1) @/tmp/bomberman-tls.rsp -lm -pthread
rm -f bomberman-mac-arm64.zip
zip -q bomberman-mac-arm64.zip bomberman-portable
