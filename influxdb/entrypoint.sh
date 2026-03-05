#!/bin/sh
# If already set up, just start influxd normally
if [ -f /var/lib/influxdb2/.influxd-initialized ]; then
  exec influxd
fi

# Start influxd in background for setup
influxd &
INFLUXD_PID=$!

# Wait for it to be ready
until influx ping --host http://localhost:8086 2>/dev/null; do
  sleep 1
done

# Run setup
influx setup \
  --host http://localhost:8086 \
  --username "${DOCKER_INFLUXDB_INIT_USERNAME}" \
  --password "${DOCKER_INFLUXDB_INIT_PASSWORD}" \
  --org "${DOCKER_INFLUXDB_INIT_ORG}" \
  --bucket "${DOCKER_INFLUXDB_INIT_BUCKET}" \
  --token "${DOCKER_INFLUXDB_INIT_ADMIN_TOKEN}" \
  --force

touch /var/lib/influxdb2/.influxd-initialized

# Bring influxd to foreground
wait $INFLUXD_PID
