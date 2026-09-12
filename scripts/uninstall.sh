#!/bin/bash
# Stops and removes the launchd jobs and binaries installed by install.sh.
# Leaves your config file (~/Library/Application Support/KnockDetector) alone.
set -uo pipefail

BIN_DIR=/usr/local/libexec/knock
DAEMON_PLIST=/Library/LaunchDaemons/local.knockd.plist
AGENT_PLIST="$HOME/Library/LaunchAgents/local.knockagent.plist"

launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null
sudo launchctl bootout system "$DAEMON_PLIST" 2>/dev/null
rm -f "$AGENT_PLIST"
sudo rm -f "$DAEMON_PLIST" /tmp/knockd.sock
sudo rm -rf "$BIN_DIR"
echo "Uninstalled. Config kept at ~/Library/Application Support/KnockDetector/"
