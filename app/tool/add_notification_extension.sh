#!/bin/sh
# Runs add_notification_extension.rb with the xcodeproj gem CocoaPods ships,
# the same way Homebrew's pod wrapper does (GEM_HOME only).
set -eu
pods=$(dirname "$(dirname "$(readlink -f "$(command -v pod)")")")/libexec
GEM_HOME="$pods" /opt/homebrew/opt/ruby/bin/ruby "$(dirname "$0")/add_notification_extension.rb"
