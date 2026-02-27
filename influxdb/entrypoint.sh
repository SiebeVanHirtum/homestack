#!/bin/sh
set -eu

# InfluxDB docker init uses a CLI config name "default".
# If the container restarts mid-init, that config may already exist and init loops forever.
# Clearing it makes the init process idempotent and allows setup to complete.
rm -f /root/.influxdbv2/configs 2>/dev/null || true
rm -rf /root/.influxdbv2 2>/dev/null || true

if [ "$#" -eq 0 ]; then
  set -- influxd
fi

exec /entrypoint.sh "$@"
