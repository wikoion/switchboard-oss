#!/bin/sh
# Builds the notification extension's code for macOS with a test driver.
set -eu
ios=$(dirname "$0")/../ios
out=$(mktemp -d)
swiftc -module-name NotificationService -o "$out/check" \
  "$ios/NotificationService/NotificationService.swift" "$ios/Runner/SharedSession.swift" \
  "$ios/NotificationServiceTests/main.swift" 2>&1 | grep -v '^$' || true
"$out/check"
