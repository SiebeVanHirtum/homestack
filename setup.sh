#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HA_CONFIG_DIR="$ROOT_DIR/data/homeassistant"
NR_DATA_DIR="$ROOT_DIR/data/nodered"
MOSQUITTO_CONFIG_DIR="$ROOT_DIR/data/mosquitto/config"
PHP_APP_DIR="$ROOT_DIR/data/php/app"
Z2M_DATA_DIR="$ROOT_DIR/data/zigbee2mqtt"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Load or create .env ──────────────────────────────────────────────────────
ENV_FILE="$ROOT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  info "Creating .env file with defaults..."
  cat > "$ENV_FILE" <<'EOF'
TZ=Europe/Brussels
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=adminpassword
INFLUXDB_ORG=homestack
INFLUXDB_BUCKET=home
INFLUXDB_TOKEN=changeme-token-please-change-this
EOF
  warn ".env created with default credentials. Edit $ENV_FILE before continuing!"
  warn "Press ENTER to continue with defaults, or Ctrl+C to edit first."
  read -r
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# ─── 1. Install Docker ────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
    return
  fi
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$USER" || true
  systemctl enable docker
  systemctl start docker
  info "Docker installed."
}

# ─── 2. Create required directories ──────────────────────────────────────────
create_dirs() {
  info "Creating data directories..."
  mkdir -p \
    "$HA_CONFIG_DIR" \
    "$NR_DATA_DIR" \
    "$ROOT_DIR/data/influxdb" \
    "$ROOT_DIR/data/mosquitto/config" \
    "$ROOT_DIR/data/mosquitto/data" \
    "$ROOT_DIR/data/mosquitto/log" \
    "$PHP_APP_DIR" \
    "$Z2M_DATA_DIR"

  chown -R 1000:1000 "$NR_DATA_DIR"
}

# ─── 3. Clone / update PHP app (HA-Configurator) ─────────────────────────────
setup_php_app() {
  if [ -d "$PHP_APP_DIR/.git" ]; then
    info "Updating existing HA-Configurator repo in $PHP_APP_DIR..."
    git -C "$PHP_APP_DIR" pull --ff-only || warn "Git pull failed, continuing with existing code."
  else
    if [ -n "$(ls -A "$PHP_APP_DIR" 2>/dev/null)" ]; then
      warn "PHP app dir $PHP_APP_DIR is not empty and not a git repo; skipping clone."
      warn "If you want HA-Configurator here, clean the directory and rerun setup.sh."
      return
    fi
    info "Cloning HA-Configurator into $PHP_APP_DIR..."
    git clone https://github.com/SiebeVanHirtum/HA-Configurator.git "$PHP_APP_DIR"

    # Copy .env.example to .env if not already present
    if [ ! -f "$PHP_APP_DIR/.env" ] && [ -f "$PHP_APP_DIR/.env.example" ]; then
      info "Copying .env.example to .env for PHP app..."
      cp "$PHP_APP_DIR/.env.example" "$PHP_APP_DIR/.env"
      warn "Review and edit $PHP_APP_DIR/.env with your actual values!"
    fi
  fi
}

# ─── 4. Mosquitto config ──────────────────────────────────────────────────────
setup_mosquitto() {
  local conf="$MOSQUITTO_CONFIG_DIR/mosquitto.conf"
  if [ -f "$conf" ]; then
    info "Mosquitto config already exists, skipping."
    return
  fi
  info "Creating Mosquitto config..."
  cat > "$conf" <<'EOF'
listener 1883
allow_anonymous true

listener 9001
protocol websockets
allow_anonymous true

persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF
}

# ─── 5. Zigbee2MQTT config ────────────────────────────────────────────────────
setup_zigbee2mqtt() {
  local conf="$Z2M_DATA_DIR/configuration.yaml"
  if [ -f "$conf" ]; then
    info "Zigbee2MQTT config already exists, skipping."
    return
  fi
  info "Creating Zigbee2MQTT config..."
  cat > "$conf" <<EOF
homeassistant:
  enabled: true
  legacy_entity_attributes: false

permit_join: false

mqtt:
  server: mqtt://mosquitto:1883

serial:
  port: /dev/ttyUSB1

frontend:
  enabled: true
  port: 8080

advanced:
  log_level: info
  network_key: GENERATE
EOF
  warn "Zigbee2MQTT config written. Check /dev/ttyUSB1 matches your Zigbee stick!"
  warn "Run 'ls /dev/ttyUSB*' or 'ls /dev/ttyACM*' to find the correct port."
}

# ─── 5. HA configuration.yaml ────────────────────────────────────────────────
# IMPORTANT: Write configuration.yaml BEFORE starting HA to avoid safe mode.
# Up-to-date pattern:
# - Connection settings (host/token/org/bucket/api_version) are still supported
#   in YAML now, but HA 2026.3+ auto-imports them into the InfluxDB integration
#   in the UI and will deprecate the YAML connection in 2026.9.0.
setup_ha_config() {
  local config="$HA_CONFIG_DIR/configuration.yaml"
  if [ -f "$config" ]; then
    info "HA configuration.yaml already exists, skipping."
    return
  fi
  info "Writing Home Assistant configuration.yaml..."
  cat > "$config" <<EOF
# Loads default set of integrations. Do not remove.
default_config:

# Text to speech
tts:
  - platform: google_translate

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

# ─── InfluxDB 2.x Integration (current recommended pattern) ───────────────────
# Connection config is still valid YAML today and will be auto-imported into
# the UI (Settings → Devices & Services → InfluxDB) on first start.
# After import, HA will ask you (via a Repair) to remove connection keys
# (api_version/host/port/ssl/token/organization/bucket) from YAML.
# Filters (include/exclude/tags) remain YAML-only, per docs:
# https://www.home-assistant.io/integrations/influxdb/
influxdb:
  api_version: 2
  ssl: false
  host: localhost
  port: 8086
  token: ${INFLUXDB_TOKEN}
  organization: ${INFLUXDB_ORG}
  bucket: ${INFLUXDB_BUCKET}
  tags:
    source: HA
  tags_attributes:
    - friendly_name
  default_measurement: units
  exclude:
    entities:
      - zone.home
    domains:
      - persistent_notification
      - person
  include:
    domains:
      - sensor
      - binary_sensor
      - sun
    entities:
      - weather.home
EOF

  # Create empty required files HA expects
  touch "$HA_CONFIG_DIR/automations.yaml"
  touch "$HA_CONFIG_DIR/scripts.yaml"
  touch "$HA_CONFIG_DIR/scenes.yaml"
}

# ─── 6. HA Dashboards (YAML) ─────────────────────────────────────────────────
# Each *.yaml in homeassistant/dashboards/ becomes a YAML dashboard registered
# in lovelace: dashboards: and shown in the sidebar.
setup_ha_dashboards() {
  local dashboard_src="$ROOT_DIR/homeassistant/dashboards"
  if [ ! -d "$dashboard_src" ] || [ -z "$(ls -A "$dashboard_src"/*.yaml 2>/dev/null)" ]; then
    warn "No dashboard YAML files found in homeassistant/dashboards/, skipping."
    return
  fi

  info "Installing HA dashboards..."
  local config="$HA_CONFIG_DIR/configuration.yaml"
  local dashboards_dir="$HA_CONFIG_DIR/dashboards"
  mkdir -p "$dashboards_dir"

  local lovelace_block="lovelace:\n  dashboards:"

  for yaml_file in "$dashboard_src"/*.yaml; do
    local filename
    filename="$(basename "$yaml_file")"
    local slug="${filename%.yaml}"
    # Slug for ID
    local safe_slug
    safe_slug="$(echo "$slug" | tr '[:upper:]' '[:lower:]' | tr '_ ' '-')"
    # Human-readable title
    local title
    title="$(echo "$slug" | tr '_-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')"

    info "  → Dashboard: $title ($filename)"
    cp "$yaml_file" "$dashboards_dir/$filename"

    lovelace_block="$lovelace_block\n    lovelace-${safe_slug}:\n      mode: yaml\n      filename: dashboards/${filename}\n      title: \"${title}\"\n      show_in_sidebar: true\n      icon: mdi:view-dashboard"
  done

  if grep -q "^lovelace:" "$config"; then
    warn "lovelace: already defined in configuration.yaml, NOT modifying it."
    warn "If you want automatic dashboard registration, remove existing lovelace:"
    warn "and rerun setup.sh, or add dashboards manually per docs."
  else
    echo -e "\n$lovelace_block" >> "$config"
  fi
}

# ─── 7. Node-RED flows ────────────────────────────────────────────────────────
setup_nodered_flows() {
  local flows_src="$ROOT_DIR/nodered/flows.json"
  if [ ! -f "$flows_src" ]; then
    warn "nodered/flows.json not found, skipping."
    return
  fi
  info "Copying Node-RED flows..."
  cp "$flows_src" "$NR_DATA_DIR/flows.json"
}

# ─── 8. Start Docker Compose ──────────────────────────────────────────────────
start_services() {
  info "Pulling Docker images..."
  cd "$ROOT_DIR"
  docker compose pull

  info "Building custom images (php-fpm)..."
  docker compose build

  info "Starting base services (mosquitto, influxdb)..."
  docker compose up -d mosquitto influxdb
  info "Waiting 15s for InfluxDB to initialize..."
  sleep 15

  info "Starting remaining services..."
  docker compose up -d
  info "All services started."
}

# ─── 9. Status ────────────────────────────────────────────────────────────────
print_status() {
  local ip
  ip="$(hostname -I | awk '{print $1}')"

  echo ""
  info "═══════════════════════════════════════════════════"
  info " Setup complete! Service URLs:"
  info "   Home Assistant : http://$ip:8123"
  info "   Node-RED       : http://$ip:1880"
  info "   InfluxDB       : http://$ip:8086"
  info "   MQTT           : mqtt://$ip:1883"
  info "   Zigbee2MQTT    : http://$ip:8080"
  info "   PHP/Nginx      : http://$ip:80"
  info "═══════════════════════════════════════════════════"
  echo ""
  warn "InfluxDB credentials (from .env):"
  warn "  User     : $INFLUXDB_USER"
  warn "  Password : $INFLUXDB_PASSWORD"
  warn "  Org      : $INFLUXDB_ORG"
  warn "  Bucket   : $INFLUXDB_BUCKET"
  warn "  Token    : $INFLUXDB_TOKEN"
  echo ""
  warn "NEXT STEPS:"
  warn "  1. Wait ~60s for Home Assistant to fully start."
  warn "  2. Complete HA onboarding at http://$ip:8123."
  warn "  3. Go to Settings → Devices & Services → InfluxDB."
  warn "     The InfluxDB integration should already exist from YAML import."
  warn "  4. When HA shows a Repair about 'InfluxDB YAML configuration being"
  warn "     removed', follow it: remove connection keys from configuration.yaml"
  warn "     and keep your include/exclude/tags there."
  warn "  5. Your YAML dashboards should appear in the sidebar."
  warn "  6. HA-Configurator PHP app should be served at http://$ip/ by php-nginx."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  info "Starting HomeStack setup..."
  install_docker
  create_dirs
  setup_php_app
  setup_mosquitto
  setup_zigbee2mqtt
  setup_ha_config        # BEFORE starting HA
  setup_ha_dashboards    # BEFORE starting HA
  setup_nodered_flows
  start_services
  print_status
}

main "$@"
