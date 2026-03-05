#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HA_CONFIG_DIR="$ROOT_DIR/data/homeassistant"
NR_DATA_DIR="$ROOT_DIR/data/nodered"
MOSQUITTO_CONFIG_DIR="$ROOT_DIR/data/mosquitto/config"

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
    "$ROOT_DIR/data/php/app"
}

# ─── 3. Mosquitto config ──────────────────────────────────────────────────────
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

# ─── 4. HA configuration.yaml ────────────────────────────────────────────────
# IMPORTANT: We write configuration.yaml BEFORE starting HA to avoid safe mode.
# HA 2026.3+ auto-imports the influxdb connection settings into the UI.
# After first boot you can remove the connection keys (host/token/org/bucket)
# from configuration.yaml — HA will show a repair notice guiding you.
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

# ─── InfluxDB 2.x Integration ─────────────────────────────────────────────────
# NOTE (HA 2026.3+): Connection settings below will be auto-imported into the UI
# (Settings → Devices & Services → InfluxDB) on first HA start.
# After that, HA will show a repair notice asking you to remove the connection
# keys (host, token, organization, bucket, api_version, ssl) from here.
# The include/exclude/tags options remain in YAML permanently.
influxdb:
  api_version: 2
  ssl: false
  host: influxdb
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

# ─── 5. HA Dashboards ─────────────────────────────────────────────────────────
# Dashboards are installed as YAML-mode dashboards via configuration.yaml.
# Each .yaml file in homeassistant/dashboards/ becomes a sidebar dashboard.
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

  # Build lovelace dashboard entries
  local lovelace_block="lovelace:\n  dashboards:"

  for yaml_file in "$dashboard_src"/*.yaml; do
    local filename
    filename="$(basename "$yaml_file")"
    local slug="${filename%.yaml}"
    # Sanitize slug: lowercase, replace underscores/spaces with hyphens
    local safe_slug
    safe_slug="$(echo "$slug" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')"
    local title
    # Title: capitalize words, replace hyphens/underscores with spaces
    title="$(echo "$slug" | tr '_-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')"

    info "  → Dashboard: $title ($filename)"
    cp "$yaml_file" "$dashboards_dir/$filename"

    lovelace_block="$lovelace_block\n    lovelace-${safe_slug}:\n      mode: yaml\n      filename: dashboards/${filename}\n      title: \"${title}\"\n      show_in_sidebar: true\n      icon: mdi:view-dashboard"
  done

  # Append lovelace block to configuration.yaml if not already present
  if grep -q "^lovelace:" "$config"; then
    warn "lovelace: block already in configuration.yaml, skipping dashboard injection."
  else
    echo -e "\n$lovelace_block" >> "$config"
  fi
}

# ─── 6. Node-RED flows ────────────────────────────────────────────────────────
setup_nodered_flows() {
  local flows_src="$ROOT_DIR/nodered/flows.json"
  if [ ! -f "$flows_src" ]; then
    warn "nodered/flows.json not found, skipping."
    return
  fi
  info "Copying Node-RED flows..."
  cp "$flows_src" "$NR_DATA_DIR/flows.json"
}

# ─── 7. Start Docker Compose ──────────────────────────────────────────────────
start_services() {
  info "Pulling Docker images..."
  cd "$ROOT_DIR"
  docker compose pull

  info "Building custom images (php-fpm)..."
  docker compose build

  info "Starting services..."
  # Start dependencies first, then everything
  docker compose up -d mosquitto influxdb
  info "Waiting 15s for InfluxDB to initialize..."
  sleep 15

  docker compose up -d
  info "All services started."
}

# ─── 8. Status ────────────────────────────────────────────────────────────────
print_status() {
  echo ""
  info "═══════════════════════════════════════════════════"
  info " Setup complete! Service URLs:"
  info "   Home Assistant : http://$(hostname -I | awk '{print $1}'):8123"
  info "   Node-RED       : http://$(hostname -I | awk '{print $1}'):1880"
  info "   InfluxDB       : http://$(hostname -I | awk '{print $1}'):8086"
  info "   MQTT           : mqtt://$(hostname -I | awk '{print $1}'):1883"
  info "   PHP/Nginx      : http://$(hostname -I | awk '{print $1}'):80"
  info "═══════════════════════════════════════════════════"
  echo ""
  warn "InfluxDB credentials:"
  warn "  User     : $INFLUXDB_USER"
  warn "  Password : $INFLUXDB_PASSWORD"
  warn "  Org      : $INFLUXDB_ORG"
  warn "  Bucket   : $INFLUXDB_BUCKET"
  warn "  Token    : $INFLUXDB_TOKEN"
  echo ""
  warn "NEXT STEPS:"
  warn "  1. Wait ~60s for Home Assistant to fully start"
  warn "  2. Complete HA onboarding at http://$(hostname -I | awk '{print $1}'):8123"
  warn "  3. HA will auto-import InfluxDB connection into Settings → Devices & Services"
  warn "  4. HA 2026.3+: After first boot, follow the repair notice to remove"
  warn "     connection keys from configuration.yaml (host/token/org/bucket)"
  warn "  5. Your dashboards are available in the HA sidebar"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  info "Starting HomeStack setup..."
  install_docker
  create_dirs
  setup_mosquitto
  setup_ha_config        # Must run BEFORE starting HA container
  setup_ha_dashboards    # Must run BEFORE starting HA container
  setup_nodered_flows
  start_services
  print_status
}

main "$@"
