# Sourced by the build scripts, from app/. SB_DEFAULT_SERVER, the server the
# sign-in screen fills in, comes from the environment or else from
# tool/local.env (git-ignored), which holds a line like
#   SB_DEFAULT_SERVER=switchboard.example.ts.net
# flutter run reads the same file:
#   flutter run --dart-define-from-file=tool/local.env
if [ -z "${SB_DEFAULT_SERVER:-}" ] && [ -f tool/local.env ]; then
  . ./tool/local.env
fi
SB_DEFAULT_SERVER=${SB_DEFAULT_SERVER:-}
[ -n "$SB_DEFAULT_SERVER" ] ||
  echo "SB_DEFAULT_SERVER isn't set, so the sign-in screen's Server field starts empty (see tool/local-env.sh)" >&2
