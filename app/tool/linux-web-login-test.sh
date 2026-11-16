#!/bin/sh
# Runs integration_test/web_login_test.dart, the real WebKitGTK sign-in window
# against a local page, under Xvfb on a private D-Bus bus, so nothing shows
# on the desktop. With a PNG path it also screenshots the app beside the
# sign-in window.
#   tool/linux-web-login-test.sh [/tmp/web-login.png]
# Needs Xvfb, xdotool, python3 and ImageMagick's import.
# It leaves the test as the debug bundle's entry point: run
# `flutter build linux --debug` before tool/linux-shot.sh.
set -eu
cd "$(dirname "$0")/.."
shot=${1:-}
flutter=${FLUTTER_ROOT:-$HOME/development/flutter}/bin/flutter
display=:${SB_XVFB_DISPLAY:-78}
x() { env DISPLAY="$display" xdotool "$@"; }

Xvfb "$display" -screen 0 1980x1000x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
# A bus with no service files, so nothing on it reaches the real session
# (portals, keyring, notifications).
bus=$(mktemp)
shooter=
trap 'kill $shooter $xvfb 2>/dev/null || true; rm -f "$bus"' EXIT
cat >"$bus" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
sleep 1

if [ -n "$shot" ]; then
  (
    login=$(x search --sync --onlyvisible --name '^Sign in to Test$' | head -n 1)
    app=$(x search --onlyvisible --name '^Switchboard$' | head -n 1)
    # No window manager under Xvfb: put the two side by side.
    x windowsize "$app" 1000 760 windowmove "$app" 0 0
    x windowmove "$login" 1010 0
    sleep 2
    import -display "$display" -window root "$shot"
  ) &
  shooter=$!
fi

dbus-run-session --config-file="$bus" -- \
  env -u GNOME_KEYRING_CONTROL -u WAYLAND_DISPLAY NO_AT_BRIDGE=1 \
  DISPLAY="$display" GDK_BACKEND=x11 \
  "$flutter" test integration_test/web_login_test.dart -d linux
