#!/bin/bash
# Installs knockd (LaunchDaemon, runs as root at boot) and KnockAgent
# (LaunchAgent, runs at login) so nothing has to be started by hand.
# Re-run after code changes to reinstall. Undo with scripts/uninstall.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR=/usr/local/libexec/knock
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

echo "==> Installing binaries to $BIN_DIR"
sudo mkdir -p "$BIN_DIR"
sudo cp .build/release/knockd .build/release/KnockAgent "$BIN_DIR/"

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
        <string>$BIN_DIR/KnockAgent</string>
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
echo "Accessibility permission to $BIN_DIR/KnockAgent (separate from the"
echo "grant you gave your terminal). Re-grant after reinstalling."
