#!/bin/bash
# Remove battguard and lidguard.
#   sudo ./uninstall.sh           both
#   ./uninstall.sh --agent-only   lidguard only, no root needed
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=local.battguard
LID=local.lidguard

remove_agent() {
    local uid; uid=$(id -u)
    launchctl bootout "gui/$uid/$LID" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LID.plist" "$HOME/bin/lidguard"
    echo "lidguard removed from $USER's session (log $HOME/Library/Logs/lidguard.log left in place)"
}

if [ "${1:-}" = --agent-only ]; then
    if [ "$(id -u)" = 0 ]; then echo "--agent-only must run as the logged-in user, not root" >&2; exit 1; fi
    remove_agent
    exit 0
fi
if [ "$(id -u)" != 0 ]; then echo "run as: sudo $0   (or: $0 --agent-only for lidguard alone)" >&2; exit 1; fi

launchctl bootout system/$LABEL 2>/dev/null || true
if [ -e /var/db/battguard/sleep-reenabled-by-battguard ]; then
    echo "battguard had cleared disablesleep; restoring closed-lid mode (disablesleep 1)"
    pmset -a disablesleep 1
fi
rm -f /Library/LaunchDaemons/$LABEL.plist /usr/local/sbin/battguard
rm -rf /var/db/battguard
echo "battguard removed (log files /var/log/battguard.* left in place)"

AGENT_USER=${SUDO_USER:-$(stat -f %Su /dev/console 2>/dev/null || true)}
if [ -n "$AGENT_USER" ] && [ "$AGENT_USER" != root ]; then
    sudo -u "$AGENT_USER" -H "$HERE/uninstall.sh" --agent-only
fi
