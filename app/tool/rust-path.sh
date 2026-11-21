# Sourced by tool/testflight.sh. Makes sure the Rust core's build can find rustc.
# cargokit builds the core with `rustup run stable cargo build`, and Cargo
# then looks rustc up on PATH. rustup adds only Cargo's own bin directory
# (~/.cargo/bin) for that, where rustup-init puts a rustc. Homebrew's rustup
# puts none there: it links just `rustup` into Homebrew's bin and keeps rustc
# and the rest in its own opt/rustup/bin, which only a shell profile adds to
# PATH. A build started without that profile (a release runner, cron, a
# command over SSH) then stops in Xcode's "Build Rust library" phase with
#   could not execute process `rustc -vV` ... No such file or directory
# So when no rustc is in reach, this adds Homebrew's rustup directory to the
# end of PATH. It changes nothing when rustc is found already.
if ! command -v rustc >/dev/null 2>&1 && [ ! -x "${CARGO_HOME:-$HOME/.cargo}/bin/rustc" ]; then
  SB_RUSTUP=$(command -v rustup 2>/dev/null || true)
  # <prefix>/bin/rustup -> <prefix>/opt/rustup/bin, for either Homebrew prefix.
  SB_RUSTUP_BIN="${SB_RUSTUP%/bin/rustup}/opt/rustup/bin"
  if [ -n "$SB_RUSTUP" ] && [ -x "$SB_RUSTUP_BIN/rustc" ]; then
    PATH="$PATH:$SB_RUSTUP_BIN"
    export PATH
  fi
  unset SB_RUSTUP SB_RUSTUP_BIN
fi
