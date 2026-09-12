#!/bin/bash
# Installs knockd (LaunchDaemon, runs as root at boot) and KnockAgent
# (LaunchAgent, runs at login) so nothing has to be started by hand.
# Re-run after code changes to reinstall. Undo with scripts/uninstall.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR=/usr/local/libexec/knock
# KnockAgent is wrapped in a minimal .app bundle: macOS's Accessibility
# permission (needed for Keystroke actions) prompts reliably and can be
# granted in System Settings only for real app bundles, not bare binaries.
APP=/Applications/KnockAgent.app
AGENT_EXE="$APP/Contents/MacOS/KnockAgent"
CONFIG="$HOME/Library/Application Support/KnockDetector/config.json"
DAEMON_LABEL=local.knockd
AGENT_LABEL=local.knockagent
DAEMON_PLIST=/Library/LaunchDaemons/$DAEMON_LABEL.plist
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

echo "==> Building release binaries"
swift build -c release

echo "==> Stopping any running instances"
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
sudo launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
pkill -x KnockAgent 2>/dev/null || true
sudo pkill -x knockd 2>/dev/null || true

echo "==> Installing knockd to $BIN_DIR"
sudo mkdir -p "$BIN_DIR"
sudo cp .build/release/knockd "$BIN_DIR/"
sudo rm -f "$BIN_DIR/KnockAgent" # from earlier installs, before the .app bundle

# macOS ties the Accessibility grant to the app's code signature. The
# linker's ad-hoc signature changes on every build, which forced a
# re-grant after each reinstall. Signing with one self-signed certificate
# (created once, kept in the login keychain) gives a stable identity so
# the grant survives rebuilds.
SIGN_ID="Knock Dev"
ensure_signing_identity() {
    if security find-identity -v -p codesigning | grep -q "\"$SIGN_ID\""; then return; fi
    echo "==> Creating self-signed code-signing certificate '$SIGN_ID' (one time; may ask for your login password)"
    local tmp; tmp=$(mktemp -d)
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_ID
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    # -legacy keeps the .p12 in a format `security import` accepts on every macOS;
    # fall back for openssl builds without the legacy provider.
    openssl pkcs12 -export -out "$tmp/knock.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout pass:knock -legacy 2>/dev/null \
        || openssl pkcs12 -export -out "$tmp/knock.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout pass:knock
    local keychain="$HOME/Library/Keychains/login.keychain-db"
    security import "$tmp/knock.p12" -k "$keychain" -P knock -T /usr/bin/codesign >/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"
    rm -rf "$tmp"
}

# Skip the KnockAgent reinstall when the binary hasn't changed, so a
# knockd-only change can't disturb the app (or its permissions).
build_hash=$(shasum -a 256 .build/release/KnockAgent | cut -d' ' -f1)
installed_hash=$(cat "$APP/Contents/Resources/build.sha256" 2>/dev/null || true)
if [ "$build_hash" = "$installed_hash" ] && codesign -dv "$APP" 2>&1 | grep -q "Authority=$SIGN_ID"; then
    echo "==> $APP is up to date, leaving it alone"
else
    ensure_signing_identity
    echo "==> Building and signing $APP"
    stage=$(mktemp -d)/KnockAgent.app
    mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
    cp .build/release/KnockAgent "$stage/Contents/MacOS/KnockAgent"
    echo "$build_hash" > "$stage/Contents/Resources/build.sha256"
    cat > "$stage/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$AGENT_LABEL</string>
    <key>CFBundleName</key><string>KnockAgent</string>
    <key>CFBundleExecutable</key><string>KnockAgent</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
    # Sign as the user (the certificate is in the login keychain, which root
    # can't see), then move into place.
    codesign --force --sign "$SIGN_ID" --identifier "$AGENT_LABEL" "$stage"
    codesign --verify --strict "$stage"
    sudo rm -rf "$APP"
    sudo cp -R "$stage" "$APP"
    rm -rf "$(dirname "$stage")"
fi

echo "==> Writing launchd plists"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# The daemon runs as root, so it is told exactly which config file to read.
sudo tee "$DAEMON_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$DAEMON_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/knockd</string>
        <string>--config</string>
        <string>$CONFIG</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/knockd.log</string>
    <key>StandardErrorPath</key><string>/var/log/knockd.log</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"

cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$AGENT_EXE</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/KnockAgent.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/KnockAgent.log</string>
</dict>
</plist>
EOF

echo "==> Starting"
# Agent first: it creates the config file on first run, which knockd watches.
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
sudo launchctl bootstrap system "$DAEMON_PLIST"

echo
echo "Installed. Both will now start automatically at boot/login."
echo "  logs:      /var/log/knockd.log, $LOG_DIR/KnockAgent.log"
echo "  uninstall: scripts/uninstall.sh"
echo
echo "NOTE: if you use Keystroke actions, macOS will ask you to grant"
echo "Accessibility permission to KnockAgent the first time one fires."
echo "If it doesn't ask, add $APP in System Settings > Privacy & Security"
echo "> Accessibility with the + button. If a stale entry is there from a"
echo "previous install, clear it first: tccutil reset Accessibility $AGENT_LABEL"
