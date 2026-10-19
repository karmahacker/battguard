#!/bin/bash
# Scenario tests for battguard: dry-run with fake battery / lid / flag inputs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export BATTGUARD_DRY_RUN=1
export BATTGUARD_STATE_DIR="$TMP/state"
export BATTGUARD_LOG="$TMP/battguard.log"
STATE="$BATTGUARD_STATE_DIR/sleep-reenabled-by-battguard"
pass=0 fail=0

batt() { printf "Now drawing from '%s'\n -InternalBattery-0 (id=22282339)\t%s%%; %s; 2:11 remaining present: true\n" "$1" "$2" "$3"; }
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; echo "      got: $2"; fail=$((fail+1)); }
has()  { printf '%s' "$2" | grep -qF -- "$1"; }
poll() { "$HERE/battguard" "$@"; }   # env vars set per call by the caller

# 1 On AC, nothing pending -> silent
out=$(BATTGUARD_FAKE_BATT="$(batt 'AC Power' 37 charging)" poll)
if [ -z "$out" ]; then ok "AC, nothing pending: no action"; else bad "AC, nothing pending" "$out"; fi

# 2 Battery, plenty left -> silent
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 50 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=closed poll)
if [ -z "$out" ]; then ok "battery 50%: no action"; else bad "battery 50%" "$out"; fi

# 3 Just above alarm level -> silent
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 11 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=closed poll)
if [ -z "$out" ]; then ok "battery 11%: no action"; else bad "battery 11%" "$out"; fi

# 4 Alarm band top: notify + say, no pmset, no state
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 10 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=closed poll)
if has "display notification" "$out" && has " say " "$out" && ! has pmset "$out" && [ ! -e "$STATE" ]; then
    ok "battery 10%: alarm only (notification + speech), no pmset"
else bad "battery 10%" "$out"; fi

# 5 Alarm band bottom (6%): still alarm only
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 6 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=open poll)
if has "display notification" "$out" && ! has pmset "$out" && [ ! -e "$STATE" ]; then
    ok "battery 6%: alarm only"
else bad "battery 6%" "$out"; fi

# 6 Sleep level, lid open -> disablesleep 0, state saved, notify, no forced sleep
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 5 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=open poll)
if has "RUN: pmset -a disablesleep 0" "$out" && has "display notification" "$out" && ! has sleepnow "$out" && [ -e "$STATE" ]; then
    ok "battery 5%, lid open: disablesleep 0, state saved, no forced sleep"
else bad "battery 5%, lid open" "$out"; fi

# 7 Charger back while state pending -> restore flag, forget state
out=$(BATTGUARD_FAKE_BATT="$(batt 'AC Power' 7 charging)" poll)
if has "RUN: pmset -a disablesleep 1" "$out" && [ ! -e "$STATE" ]; then
    ok "charger back: disablesleep 1, state cleared"
else bad "charger back" "$out"; fi

# 8 Below sleep level, lid closed -> disablesleep 0, notify, sleepnow
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 4 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=closed poll)
if has "RUN: pmset -a disablesleep 0" "$out" && has "display notification" "$out" && has "RUN: pmset sleepnow" "$out"; then
    ok "battery 4%, lid closed: disablesleep 0, notify, sleepnow"
else bad "battery 4%, lid closed" "$out"; fi
rm -f "$STATE"

# 9 Low battery but closed-lid mode already off -> macOS handles it, we stay silent
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 7 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=0 BATTGUARD_FAKE_LID=closed poll)
if [ -z "$out" ] && [ ! -e "$STATE" ]; then ok "battery 7%, sleep already enabled: no action"; else bad "battery 7%, sleep enabled" "$out"; fi

# 10 Custom levels: warn 20 / sleep 15
out=$(BATTGUARD_WARN_AT=20 BATTGUARD_SLEEP_AT=15 BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 18 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=open poll)
if has "display notification" "$out" && ! has pmset "$out"; then ok "custom 20/15, battery 18%: alarm"; else bad "custom 20/15 at 18%" "$out"; fi
out=$(BATTGUARD_WARN_AT=20 BATTGUARD_SLEEP_AT=15 BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 15 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=open poll)
if has "RUN: pmset -a disablesleep 0" "$out"; then ok "custom 20/15, battery 15%: sleep action"; else bad "custom 20/15 at 15%" "$out"; fi
rm -f "$STATE"

# 11 No battery at all (desktop) -> silent
out=$(BATTGUARD_FAKE_BATT="Now drawing from 'AC Power'" poll)
if [ -z "$out" ]; then ok "no battery: no action"; else bad "no battery" "$out"; fi

# 12 SleepDisabled line absent (flag off) is treated as 0
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 3 discharging)" BATTGUARD_FAKE_SLEEPDISABLED= BATTGUARD_FAKE_LID=closed poll)
if [ -z "$out" ]; then ok "SleepDisabled absent: treated as 0, no action"; else bad "SleepDisabled absent" "$out"; fi

# 13 --status never acts
out=$(BATTGUARD_FAKE_BATT="$(batt 'Battery Power' 3 discharging)" BATTGUARD_FAKE_SLEEPDISABLED=1 BATTGUARD_FAKE_LID=closed poll --status)
if has "battery      : 3%" "$out" && has "sleep below  : 5%" "$out" && ! has "RUN:" "$out" && [ ! -e "$STATE" ]; then ok "--status reports without acting"; else bad "--status" "$out"; fi


# --- lidguard (lid closed -> display sleep): build, decision-logic self-test, status, dry run ---
export LIDGUARD_LOG="$TMP/lidguard.log"
if "$HERE/build.sh" >/dev/null 2>"$TMP/build.err"; then
    ok "lidguard builds"
    out=$("$HERE/lidguard" --selftest 2>&1)
    if ! has FAIL "$out" && has "all " "$out"; then ok "lidguard --selftest: $(printf '%s\n' "$out" | tail -1)"; else bad "lidguard --selftest" "$out"; fi
    out=$("$HERE/lidguard" --status 2>&1)
    if has "lid " "$out" && has "display " "$out"; then ok "lidguard --status reports lid and display state"; else bad "lidguard --status" "$out"; fi
    # dry run for 2 s: must start, log, and never call pmset
    "$HERE/lidguard" --dry-run >/dev/null 2>&1 & lid_pid=$!
    sleep 2; kill "$lid_pid" 2>/dev/null; wait "$lid_pid" 2>/dev/null
    out=$(cat "$LIDGUARD_LOG" 2>/dev/null)
    if has "lidguard started (dry run)" "$out" && ! has "pmset displaysleepnow)" "$out"; then ok "lidguard --dry-run starts and logs"; else bad "lidguard --dry-run" "$out"; fi
else
    bad "lidguard builds" "$(cat "$TMP/build.err")"
fi
echo
echo "passed $pass, failed $fail"
echo "--- log written during tests ---"
cat "$BATTGUARD_LOG" 2>/dev/null
[ "$fail" = 0 ]
