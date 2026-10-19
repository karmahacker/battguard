#!/bin/bash
# Install battguard (root launchd daemon) and lidguard (launchd agent in the
# login session of the user who ran sudo).
#   sudo ./install.sh           both
#   ./install.sh --agent-only   lidguard only, no root needed
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=local.battguard
LID=local.lidguard

install_agent() {   # runs as the logged-in user
    local uid; uid=$(id -u)
    if ! { [ -x "$HERE/lidguard" ] && [ "$HERE/lidguard" -nt "$HERE/lidguard.swift" ]; }; then "$HERE/build.sh"; fi
    mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    install -m 755 "$HERE/lidguard" "$HOME/bin/lidguard"
    sed "s|__HOME__|$HOME|g" "$HERE/$LID.plist" > "$HOME/Library/LaunchAgents/$LID.plist"
    plutil -lint "$HOME/Library/LaunchAgents/$LID.plist"
    launchctl bootout "gui/$uid/$LID" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/$LID.plist"
    sleep 1
    echo
    echo "lidguard installed and running in $USER's login session. Current view:"
    "$HOME/bin/lidguard" --status
    echo
    echo "log: $HOME/Library/Logs/lidguard.log   stop: launchctl bootout gui/$uid/$LID   remove: $HERE/uninstall.sh --agent-only"
}

if [ "${1:-}" = --agent-only ]; then
    if [ "$(id -u)" = 0 ]; then echo "--agent-only must run as the logged-in user, not root" >&2; exit 1; fi
    install_agent
    exit 0
fi
if [ "$(id -u)" != 0 ]; then echo "run as: sudo $0   (or: $0 --agent-only for lidguard alone)" >&2; exit 1; fi

mkdir -p /usr/local/sbin /var/db/battguard
install -o root -g wheel -m 755 "$HERE/battguard" /usr/local/sbin/battguard
install -o root -g wheel -m 644 "$HERE/$LABEL.plist" /Library/LaunchDaemons/$LABEL.plist
plutil -lint /Library/LaunchDaemons/$LABEL.plist

launchctl bootout system/$LABEL 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist
sleep 1
echo
echo "battguard installed and running (polls every 60 s). Current view:"
/usr/local/sbin/battguard --status
echo
echo "log: /var/log/battguard.log   status: sudo battguard --status   remove: sudo $HERE/uninstall.sh"

# lidguard belongs to the login session of the user who ran sudo (else whoever owns the console)
AGENT_USER=${SUDO_USER:-$(stat -f %Su /dev/console 2>/dev/null || true)}
if [ -n "$AGENT_USER" ] && [ "$AGENT_USER" != root ]; then
    sudo -u "$AGENT_USER" -H "$HERE/install.sh" --agent-only
else
    echo "no logged-in user found: install lidguard later with: $HERE/install.sh --agent-only"
fi
