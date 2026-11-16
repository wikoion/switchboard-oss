#!/bin/sh
# Same contract as the mautrix images: write an example config, then a
# registration, then run.

if [[ -z "$GID" ]]; then
	GID="$UID"
fi

if [[ ! -f /data/config.yaml ]]; then
	/usr/bin/sb-matrix -c /data/config.yaml -e
	echo "Wrote an example config to /data/config.yaml."
	exit
fi

if [[ ! -f /data/registration.yaml ]]; then
	/usr/bin/sb-matrix -g -c /data/config.yaml -r /data/registration.yaml || exit $?
	echo "Wrote /data/registration.yaml."
	exit
fi

cd /data
chown -R $UID:$GID /data
exec su-exec $UID:$GID /usr/bin/sb-matrix
