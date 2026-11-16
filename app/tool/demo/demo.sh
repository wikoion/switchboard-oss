#!/bin/sh
# A throwaway demo backend with fictional chats, for screenshots.
#
#   demo.sh up      start it and seed it; prints the server and password
#   demo.sh unread  send the unread messages, once the app has synced
#   demo.sh down    stop it and delete everything it made
#
# It runs its own Synapse and Caddy containers (sbdemo-*) on their own
# Docker network and volume, the Hub from sb/ on this machine, and
# stand-ins for the bridges' provisioning APIs. No bridges, no tailnet and
# no real accounts: it doesn't touch a Switchboard install. The app reaches
# it at http://localhost:$SB_DEMO_PORT (plain HTTP on this machine only;
# the iOS Simulator shares the Mac's localhost).
#
# Build the app against it (more in docs/DEVELOPMENT.md):
#   flutter build ios --simulator --debug \
#     --dart-define=SB_DEFAULT_SERVER=http://localhost:18480 \
#     --dart-define=SB_DEV_USER=alex --dart-define=SB_DEV_PASSWORD=<printed>
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
tmp=${TMPDIR:-/tmp}
state=${SB_DEMO_DIR:-${tmp%/}/switchboard-demo}
port=${SB_DEMO_PORT:-18480}
hub_port=${SB_DEMO_HUB_PORT:-18490}
bridge_port=${SB_DEMO_BRIDGE_PORT:-18501}
domain=demo.internal
owner=alex
synapse_image=matrixdotorg/synapse:$(sed -n 's/^SYNAPSE_TAG=//p' "$repo/deploy/versions.env")
caddy_image=caddy:$(sed -n 's/^CADDY_TAG=//p' "$repo/deploy/versions.env")
url=http://localhost:$port

# A private Docker config, as sb uses: Docker Desktop's credential helper can
# hang on a Keychain prompt when pulling.
docker_env() {
  if [ -z "${DOCKER_HOST:-}" ]; then
    DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
    export DOCKER_HOST
  fi
  mkdir -p "$state/docker"
  [ -f "$state/docker/config.json" ] || echo '{}' > "$state/docker/config.json"
  DOCKER_CONFIG=$state/docker
  export DOCKER_CONFIG
}

secret() {
  f=$state/secrets/$1
  [ -f "$f" ] || { mkdir -p "$state/secrets"; openssl rand -hex 24 > "$f"; }
  cat "$f"
}

render() {
  sed -e "s|@DOMAIN@|$domain|g" -e "s|@DOMAIN_RE@|$(echo "$domain" | sed 's/\./\\\\./g')|g" \
    -e "s|@OWNER@|$owner|g" -e "s|@PUBLIC_URL@|$url|g" -e "s|@HUB_PORT@|$hub_port|g" \
    -e "s|@REG_SECRET@|$(secret registration)|g" -e "s|@MACAROON@|$(secret macaroon)|g" \
    -e "s|@FORM@|$(secret form)|g" -e "s|@AS_TOKEN@|$(secret as_token)|g" \
    -e "s|@HS_TOKEN@|$(secret hs_token)|g" "$here/$1.in" > "$state/config/$1"
}

wait_for() {
  i=0
  until curl -fs -o /dev/null "$1"; do
    i=$((i + 1))
    [ $i -lt 60 ] || { echo "timed out waiting for $1" >&2; exit 1; }
    sleep 1
  done
}

up() {
  docker_env
  mkdir -p "$state/config"
  for f in homeserver.yaml demo-as.yaml Caddyfile; do render "$f"; done
  cp "$here/log.config" "$state/config/"
  [ -f "$state/config/signing.key" ] ||
    echo "ed25519 a_demo $(openssl rand -base64 32 | tr -d '=')" > "$state/config/signing.key"
  python3 "$here/fake_bridges.py" hub-config "@$owner:$domain" "$url" "127.0.0.1:$hub_port" "$bridge_port" \
    > "$state/config/hub.yaml"

  docker network inspect sbdemo >/dev/null 2>&1 || docker network create sbdemo >/dev/null
  docker volume create sbdemo-synapse-data >/dev/null
  docker run -d --name sbdemo-synapse --network sbdemo \
    -v sbdemo-synapse-data:/data -v "$state/config:/config:ro" \
    -e SYNAPSE_CONFIG_PATH=/config/homeserver.yaml \
    --entrypoint /bin/sh "$synapse_image" -c 'chown -R 991:991 /data && exec /start.py' >/dev/null
  docker run -d --name sbdemo-caddy --network sbdemo -p "127.0.0.1:$port:80" \
    -v "$state/config/Caddyfile:/etc/caddy/Caddyfile:ro" "$caddy_image" >/dev/null
  wait_for "$url/_matrix/client/versions"

  (cd "$repo/sb" && go build -o "$state/hub" ./cmd/hub)
  "$state/hub" -config "$state/config/hub.yaml" > "$state/hub.log" 2>&1 &
  echo $! > "$state/hub.pid"
  python3 "$here/fake_bridges.py" serve "$domain" "$bridge_port" > "$state/bridges.log" 2>&1 &
  echo $! > "$state/bridges.pid"

  password=$(secret password)
  docker exec sbdemo-synapse register_new_matrix_user -c /config/homeserver.yaml \
    -u "$owner" -p "$password" --no-admin http://localhost:8008 >/dev/null
  echo "Seeding:"
  seed chats
  cat <<EOF

Demo backend is up.
  Server    $url
  Username  $owner
  Password  $password
Sign in from the app, let it sync, then run: $0 unread
Stop it and delete everything with: $0 down
EOF
}

seed() {
  python3 "$here/seed.py" "$1" "$url" "$domain" "$owner" "$(secret as_token)" "$state/unread.json"
}

down() {
  docker_env
  for p in hub bridges; do
    [ -f "$state/$p.pid" ] && kill "$(cat "$state/$p.pid")" 2>/dev/null || true
  done
  docker rm -f sbdemo-synapse sbdemo-caddy >/dev/null 2>&1 || true
  docker volume rm sbdemo-synapse-data >/dev/null 2>&1 || true
  docker network rm sbdemo >/dev/null 2>&1 || true
  rm -rf "$state"
  echo "Demo backend removed."
}

case ${1:-} in
  up) up ;;
  unread) seed unread ;;
  down) down ;;
  *) echo "usage: $0 up|unread|down" >&2; exit 2 ;;
esac
