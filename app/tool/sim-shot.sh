#!/bin/sh
# Installs the last Simulator build, opens it at a route and screenshots it.
#   tool/sim-shot.sh /accounts out.png [wait-seconds]
# Build first with tool/sim-build.sh. SB_SIM picks the Simulator (UDID or
# "booted").
set -eu
route=${1:-/}
out=${2:-/tmp/switchboard-sim.png}
wait=${3:-6}
sim=${SB_SIM:-booted}
app=$(dirname "$0")/../build/ios/iphonesimulator/Runner.app
id=com.richarddraycott.switchboard
xcrun simctl terminate "$sim" "$id" 2>/dev/null || true
xcrun simctl install "$sim" "$app"
support=$(xcrun simctl get_app_container "$sim" "$id" data)/Library/Application\ Support
mkdir -p "$support"
printf '%s' "$route" > "$support/dev_route"
xcrun simctl launch "$sim" "$id" >/dev/null
sleep "$wait"
xcrun simctl io "$sim" screenshot "$out" >/dev/null 2>&1
echo "$out"
