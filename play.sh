#!/bin/sh
# One-line installer & auto-updater for Goose Bomberman on Apple Silicon Macs.
# Usage: curl -fsSL https://colemanbroad.github.io/bomberman/play.sh | sh
set -eu

REPO="colemanbroad/bomberman"
DIR="$HOME/.bomberman"
BIN="$DIR/bomberman-portable"
VER_FILE="$DIR/version.txt"
APP="$HOME/Applications/Bomberman.app"

mkdir -p "$DIR"

# Detect latest release tag via redirect (avoids GitHub API rate limits)
LATEST=$(curl -fsSI --max-time 5 "https://github.com/$REPO/releases/latest" 2>/dev/null \
  | awk -F/ '/^[Ll]ocation:/ {print $NF}' | tr -d '\r\n' || true)
CUR=$(cat "$VER_FILE" 2>/dev/null || true)

if [ ! -x "$BIN" ] || { [ -n "$LATEST" ] && [ "$LATEST" != "$CUR" ]; }; then
  echo "Downloading Goose Bomberman ${LATEST:-latest}..."
  TMP_ZIP=$(mktemp /tmp/bomberman.XXXXXX.zip)
  trap 'rm -f "$TMP_ZIP"' EXIT
  curl -fsSL "https://github.com/$REPO/releases/latest/download/bomberman-mac-arm64.zip" -o "$TMP_ZIP"
  unzip -qo "$TMP_ZIP" -d "$DIR"
  chmod +x "$BIN"
  xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
  [ -n "$LATEST" ] && printf '%s\n' "$LATEST" > "$VER_FILE"
  rm -f "$TMP_ZIP"
fi

# Create/refresh clickable ~/Applications/Bomberman.app launcher
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Bomberman</string>
  <key>CFBundleDisplayName</key><string>Goose Bomberman</string>
  <key>CFBundleIdentifier</key><string>io.github.colemanbroad.bomberman</string>
  <key>CFBundleExecutable</key><string>Bomberman</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

cat > "$APP/Contents/MacOS/Bomberman" << 'EOF'
#!/bin/sh
set -eu
REPO="colemanbroad/bomberman"
DIR="$HOME/.bomberman"
BIN="$DIR/bomberman-portable"
VER_FILE="$DIR/version.txt"
mkdir -p "$DIR"
LATEST=$(curl -fsSI --max-time 4 "https://github.com/$REPO/releases/latest" 2>/dev/null \
  | awk -F/ '/^[Ll]ocation:/ {print $NF}' | tr -d '\r\n' || true)
CUR=$(cat "$VER_FILE" 2>/dev/null || true)
if [ ! -x "$BIN" ] || { [ -n "$LATEST" ] && [ "$LATEST" != "$CUR" ]; }; then
  TMP_ZIP=$(mktemp /tmp/bomberman.XXXXXX.zip)
  if curl -fsSL --max-time 30 "https://github.com/$REPO/releases/latest/download/bomberman-mac-arm64.zip" -o "$TMP_ZIP" 2>/dev/null; then
    unzip -qo "$TMP_ZIP" -d "$DIR"
    chmod +x "$BIN"
    xattr -d com.apple.quarantine "$BIN" 2>/dev/null || true
    [ -n "$LATEST" ] && printf '%s\n' "$LATEST" > "$VER_FILE"
  fi
  rm -f "$TMP_ZIP"
fi
cd "$DIR"
exec "$BIN" "$@"
EOF
chmod +x "$APP/Contents/MacOS/Bomberman"

echo "Installed ~/Applications/Bomberman.app (auto-updates on launch)."
cd "$DIR"
exec "$BIN" "$@"
