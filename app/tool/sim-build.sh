#!/bin/sh
# Debug Simulator build that signs in by itself with the owner password
# from the backend's secrets. The password stays in this local build only.
set -eu
cd "$(dirname "$0")/.."
. tool/local-env.sh
pw=$(cd ../deploy && ../bin/sb secret get ADMIN_PASSWORD)
flutter build ios --simulator --debug --dart-define=SB_DEV_PASSWORD="$pw" \
  --dart-define=SB_DEFAULT_SERVER="$SB_DEFAULT_SERVER" "$@"
