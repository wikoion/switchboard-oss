#!/bin/sh
# Opens a route in the debug Linux build under Xvfb and screenshots it, so
# nothing shows on the desktop. The app restores the saved session.
#   tool/linux-shot.sh /accounts /tmp/shot.png [1280x800]
# SB_SHOT_WAIT sets the seconds to wait before the shot (default 8).
set -eu
cd "$(dirname "$0")/.."
# The app is single-instance and two copies must not share the store.
if pgrep -x switchboard >/dev/null; then
  echo "Switchboard is already running; close it first" >&2
  exit 1
fi
route=$1
out=$2
size=${3:-1280x800}
data=${XDG_DATA_HOME:-$HOME/.local/share}/com.richarddraycott.switchboard
mkdir -p "$data"
printf '%s' "$route" >"$data/dev_route"

display=:${SB_XVFB_DISPLAY:-77}
Xvfb "$display" -screen 0 "${size}x24" -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
app=
trap 'kill $app $xvfb 2>/dev/null || true' EXIT
sleep 1

env DISPLAY="$display" GDK_BACKEND=x11 WAYLAND_DISPLAY= \
  build/linux/x64/debug/bundle/switchboard >"${out%.png}.log" 2>&1 &
app=$!
sleep 2
# No window manager runs under Xvfb, so size the window to the screen.
env DISPLAY="$display" xdotool search --sync --class switchboard | while read -r w; do
  env DISPLAY="$display" xdotool windowsize "$w" "${size%x*}" "${size#*x}"
done
sleep "${SB_SHOT_WAIT:-8}"
import -display "$display" -window root "$out"
