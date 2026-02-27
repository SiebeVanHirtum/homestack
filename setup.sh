#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

DOCKER="docker"
COMPOSE=""   # will become either: "$DOCKER compose" OR "docker-compose"/"sudo docker-compose"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

detect_docker_cmd() {
  if command -v docker &>/dev/null && docker ps &>/dev/null; then
    DOCKER="docker"
  elif command -v docker &>/dev/null; then
    DOCKER="sudo docker"
  else
    DOCKER="docker"
  fi
}

detect_compose_cmd() {
  if $DOCKER compose version &>/dev/null; then
    COMPOSE="$DOCKER compose"
    return
  fi

  if command -v docker-compose &>/dev/null; then
    if [[ "$DOCKER" == sudo\ docker ]]; then
      COMPOSE="sudo docker-compose"
    else
      COMPOSE="docker-compose"
    fi
    return
  fi

  COMPOSE=""
}

purge_bad_docker_apt_repo() {
  local pattern="download.docker.com/linux/ubuntu"
  local hits=()

  while IFS= read -r -d '' f; do
    hits+=("$f")
  done < <(grep -RIlZ "$pattern" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)

  if ((${#hits[@]} == 0)); then
    return
  fi

  warn "Found APT entries pointing to Docker's Ubuntu repo (breaks apt on Debian trixie)."
  for f in "${hits[@]}"; do
    if [[ "$f" == "/etc/apt/sources.list" ]]; then
      warn "Bad entry is in /etc/apt/sources.list (not auto-editing). Remove that line manually, then re-run."
      continue
    fi
    warn "Removing broken repo file: $f"
    sudo rm -f "$f"
  done

  if [[ -f /etc/apt/keyrings/docker.gpg ]]; then
    warn "Removing /etc/apt/keyrings/docker.gpg (cleanup)"
    sudo rm -f /etc/apt/keyrings/docker.gpg
  fi
}

install_docker_and_compose() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    err "/etc/os-release not found; cannot detect distro"
  fi

  if ! command -v apt-get &>/dev/null; then
    err "This script currently expects apt-get on your system. Install Docker/Compose manually otherwise."
  fi

  if [[ "${ID:-}" == "debian" ]]; then
    purge_bad_docker_apt_repo
  fi

  sudo apt-get update

  if ! command -v docker &>/dev/null; then
    log "Installing Docker Engine from OS repos..."
    sudo apt-get install -y docker.io
    sudo systemctl enable --now docker
  else
    log "Docker already installed: $(docker --version)"
  fi

  sudo usermod -aG docker "$USER" || true
  detect_docker_cmd

  detect_compose_cmd
  if [[ -z "$COMPOSE" ]]; then
    log "Installing Docker Compose (Debian-friendly packages)..."
    if sudo apt-get install -y docker-compose-v2 2>/dev/null; then
      :
    elif sudo apt-get install -y docker-compose 2>/dev/null; then
      :
    else
      err "Could not install Docker Compose from apt. Install Compose manually, then re-run."
    fi
  fi

  detect_compose_cmd
  [[ -n "$COMPOSE" ]] || err "Docker Compose is still not available."

  log "Using Docker cmd: $DOCKER"
  log "Using Compose cmd: $COMPOSE"
}

ensure_host_tools() {
  # Needed for HACS install-on-host approach + token generation fallback
  if command -v apt-get &>/dev/null; then
    local pkgs=()
    command -v curl &>/dev/null || pkgs+=(curl)
    command -v wget &>/dev/null || pkgs+=(wget)
    command -v unzip &>/dev/null || pkgs+=(unzip)
    command -v openssl &>/dev/null || pkgs+=(openssl)

    if ((${#pkgs[@]} > 0)); then
      log "Installing required tools: ${pkgs[*]}"
      sudo apt-get update
      sudo apt-get install -y "${pkgs[@]}"
    fi
  fi
}

create_dirs() {
  log "Creating data directories under $DATA_DIR"
  mkdir -p \
    "$DATA_DIR/homeassistant" \
    "$DATA_DIR/nodered" \
    "$DATA_DIR/influxdb" \
    "$DATA_DIR/mosquitto/config" \
    "$DATA_DIR/mosquitto/data" \
    "$DATA_DIR/mosquitto/log" \
    "$DATA_DIR/laravel/app"
}

fix_nodered_permissions() {
  # Node-RED image runs as uid/gid 1000 by default; bind mount must be writable
  if [[ -d "$DATA_DIR/nodered" ]]; then
    log "Fixing Node-RED data directory permissions (uid:gid 1000:1000)"
    sudo chown -R 1000:1000 "$DATA_DIR/nodered" || true
    sudo chmod -R u+rwX,g+rwX "$DATA_DIR/nodered" || true
  fi
}

write_configs() {
  local MOSQ_CONF="$SCRIPT_DIR/mosquitto/mosquitto.conf"
  local MOSQ_DEST="$DATA_DIR/mosquitto/config/mosquitto.conf"
  if [[ -f "$MOSQ_CONF" ]]; then
    log "Using repo mosquitto.conf"
    cp "$MOSQ_CONF" "$MOSQ_DEST"
  elif [[ ! -f "$MOSQ_DEST" ]]; then
    log "Generating default mosquitto.conf"
    cat > "$MOSQ_DEST" <<'EOF'
listener 1883
listener 9001
protocol websockets
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF
  fi

  local NGX_CONF="$SCRIPT_DIR/laravel/nginx.conf"
  if [[ ! -f "$NGX_CONF" ]]; then
    log "Generating default laravel/nginx.conf"
    mkdir -p "$SCRIPT_DIR/laravel"
    cat > "$NGX_CONF" <<'EOF'
server {
    listen 80;
    root /var/www/html/public;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass laravel-php:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF
  fi

  local LARAVEL_DF="$SCRIPT_DIR/laravel/Dockerfile"
  if [[ ! -f "$LARAVEL_DF" ]]; then
    log "Generating default laravel/Dockerfile"
    mkdir -p "$SCRIPT_DIR/laravel"
    cat > "$LARAVEL_DF" <<'EOF'
FROM php:8.2-fpm
RUN apt-get update && apt-get install -y \
    git curl zip unzip libpng-dev libonig-dev libxml2-dev \
    && docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
EOF
  fi

  local HA_CONF="$DATA_DIR/homeassistant/configuration.yaml"
  if [[ ! -f "$HA_CONF" ]]; then
    log "Generating default HA configuration.yaml"
    cat > "$HA_CONF" <<'EOF'
homeassistant:
  name: Home
  unit_system: metric
  time_zone: Europe/Brussels

default_config:

lovelace:
  mode: yaml
  dashboards:
    main-dashboard:
      mode: yaml
      filename: dashboards/main_dash.yaml
      title: Main Dashboard
      icon: mdi:home
      show_in_sidebar: true
EOF
  fi

  local ENV_FILE="$SCRIPT_DIR/.env"
  if [[ ! -f "$ENV_FILE" ]]; then
    log "Generating .env file"
    cat > "$ENV_FILE" <<EOF
TZ=Europe/Brussels
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=adminpassword
INFLUXDB_ORG=homestack
INFLUXDB_BUCKET=home
INFLUXDB_TOKEN=changeme-token
EOF
    warn "Default credentials written to .env — change them before exposing to the internet!"
  fi
}

copy_optional_files() {
  local NR_SRC="$SCRIPT_DIR/nodered/flows.json"
  local NR_DEST="$DATA_DIR/nodered/flows.json"
  if [[ -f "$NR_SRC" ]]; then
    log "Installing Node-RED flows from repo"
    cp "$NR_SRC" "$NR_DEST"
  else
    warn "nodered/flows.json not found in repo — Node-RED will start empty"
  fi

  local NR_PKG="$SCRIPT_DIR/nodered/package.json"
  if [[ -f "$NR_PKG" ]]; then
    log "Installing Node-RED package.json from repo"
    cp "$NR_PKG" "$DATA_DIR/nodered/package.json"
  fi

  local DASH_SRC="$SCRIPT_DIR/homeassistant/dashboards"
  local DASH_DEST="$DATA_DIR/homeassistant/dashboards"
  if [[ -d "$DASH_SRC" ]]; then
    log "Installing HA dashboards from repo"
    mkdir -p "$DASH_DEST"
    cp -r "$DASH_SRC/." "$DASH_DEST/"
  else
    warn "homeassistant/dashboards/ not found in repo — creating empty placeholder"
    mkdir -p "$DASH_DEST"
    if [[ ! -f "$DASH_DEST/main_dash.yaml" ]]; then
      cat > "$DASH_DEST/main_dash.yaml" <<'EOF'
views:
  - title: Home
    cards:
      - type: markdown
        content: "## Welcome to Homestack!\nAdd your cards here."
EOF
    fi
  fi

  local SEC_DEST="$DATA_DIR/homeassistant/secrets.yaml"
  if [[ ! -f "$SEC_DEST" ]]; then
    log "Creating secrets.yaml for HA"
    cat > "$SEC_DEST" <<'EOF'
# Add your secrets here
EOF
  fi
}

read_env_var() {
  # Reads KEY from $SCRIPT_DIR/.env without sourcing arbitrary shell
  local key="$1"
  local file="$SCRIPT_DIR/.env"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" 'BEGIN{found=0} $1==k{print substr($0, index($0,$2)); found=1} END{exit(found?0:1)}' "$file"
}

set_env_var() {
  local key="$1"
  local value="$2"
  local file="$SCRIPT_DIR/.env"
  [[ -f "$file" ]] || err ".env not found at $file"

  if grep -qE "^${key}=" "$file"; then
    # replace line
    sudo sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" | sudo tee -a "$file" >/dev/null
  fi
}

ensure_influx_token() {
  local influx_dir="$DATA_DIR/influxdb"
  local bolt="$influx_dir/influxd.bolt"
  local current_token
  current_token="$(read_env_var INFLUXDB_TOKEN || echo "")"

  # If influx is already initialized, do NOT change token automatically (would desync)
  if [[ -f "$bolt" ]]; then
    log "InfluxDB already initialized (found influxd.bolt). Keeping existing INFLUXDB_TOKEN from .env."
    return
  fi

  # If token is missing or default, generate a new one for first-time setup
  if [[ -z "$current_token" || "$current_token" == "changeme-token" ]]; then
    log "Generating secure InfluxDB admin token (first-time setup)..."
    local new_token=""
    if command -v openssl &>/dev/null; then
      new_token="$(openssl rand -hex 32)"
    else
      new_token="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 64)"
    fi
    set_env_var INFLUXDB_TOKEN "$new_token"
    log "Wrote INFLUXDB_TOKEN to .env"
  fi
}

ensure_ha_influxdb_config() {
  local ha_conf="$DATA_DIR/homeassistant/configuration.yaml"
  local sec="$DATA_DIR/homeassistant/secrets.yaml"

  [[ -f "$ha_conf" ]] || err "HA configuration.yaml not found at $ha_conf"
  [[ -f "$sec" ]] || err "HA secrets.yaml not found at $sec"

  if ! grep -qE '^[[:space:]]*influxdb:' "$ha_conf"; then
    log "Adding InfluxDB v2 integration block to Home Assistant configuration.yaml"
    cat >> "$ha_conf" <<'EOF'

influxdb:
  api_version: 2
  host: 127.0.0.1
  port: 8086
  ssl: false
  token: !secret influxdb_token
  organization: !secret influxdb_org
  bucket: !secret influxdb_bucket
EOF
  else
    log "Home Assistant configuration.yaml already contains an influxdb: block (leaving as-is)."
  fi

  # Secrets: only append if missing (don’t overwrite user edits)
  local tok org bucket
  tok="$(read_env_var INFLUXDB_TOKEN || echo "")"
  org="$(read_env_var INFLUXDB_ORG || echo "homestack")"
  bucket="$(read_env_var INFLUXDB_BUCKET || echo "home")"

  if ! grep -qE '^[[:space:]]*influxdb_token:' "$sec"; then
    log "Adding influxdb_token to secrets.yaml"
    echo "influxdb_token: \"${tok}\"" >> "$sec"
  fi
  if ! grep -qE '^[[:space:]]*influxdb_org:' "$sec"; then
    log "Adding influxdb_org to secrets.yaml"
    echo "influxdb_org: \"${org}\"" >> "$sec"
  fi
  if ! grep -qE '^[[:space:]]*influxdb_bucket:' "$sec"; then
    log "Adding influxdb_bucket to secrets.yaml"
    echo "influxdb_bucket: \"${bucket}\"" >> "$sec"
  fi
}

start_stack() {
  [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || err "docker-compose.yml not found next to setup.sh"
  log "Starting stack..."
  cd "$SCRIPT_DIR"
  $COMPOSE up -d --remove-orphans
  log "Stack started."
}

init_laravel() {
  if [[ -f "$DATA_DIR/laravel/app/artisan" ]]; then
    log "Laravel already initialized, skipping."
    return
  fi
  log "Initializing Laravel project..."
  $DOCKER exec laravel-php bash -c "
    composer create-project laravel/laravel /tmp/laravel --prefer-dist --quiet &&
    cp -r /tmp/laravel/. /var/www/html/ &&
    chown -R www-data:www-data /var/www/html
  " || warn "Laravel init failed (container may still be building). Re-run setup.sh later."
}

install_hacs() {
  local marker="$DATA_DIR/homeassistant/custom_components/hacs"
  if [[ -d "$marker" ]]; then
    log "HACS already installed, skipping."
    return
  fi

  log "Installing HACS into $DATA_DIR/homeassistant (host-side, bash-safe)..."
  ensure_host_tools

  # Run the official installer *from within the HA config directory*
  (
    cd "$DATA_DIR/homeassistant"
    if command -v curl &>/dev/null; then
      curl -fsSL https://get.hacs.xyz | bash -
    else
      wget -qO- https://get.hacs.xyz | bash -
    fi
  ) || warn "HACS install failed (will need manual install)."

  log "Restarting Home Assistant..."
  $DOCKER restart homeassistant || true
}

main() {
  log "=== Homestack Setup ==="
  log "Script directory: $SCRIPT_DIR"

  install_docker_and_compose

  create_dirs
  write_configs
  copy_optional_files

  # Fix Node-RED permissions BEFORE starting containers (prevents EACCES crash)
  fix_nodered_permissions

  # Make Influx token sane BEFORE starting Influx for the first time
  ensure_influx_token

  # Ensure HA is configured to write to InfluxDB v2
  ensure_ha_influxdb_config

  start_stack
  init_laravel
  install_hacs

  echo ""
  log "=== Setup Complete ==="

  local HOST_IP="127.0.0.1"
  if command -v hostname &>/dev/null && hostname -I &>/dev/null; then
    HOST_IP="$(hostname -I | awk '{print $1}')"
  fi

  echo -e "  Home Assistant : ${GREEN}http://${HOST_IP}:8123${NC}"
  echo -e "  Node-RED       : ${GREEN}http://${HOST_IP}:1880${NC}"
  echo -e "  InfluxDB       : ${GREEN}http://${HOST_IP}:8086${NC}"
  echo -e "  Laravel        : ${GREEN}http://${HOST_IP}:8080${NC}"
  echo -e "  MQTT           : ${GREEN}${HOST_IP}:1883${NC}"

  echo ""
  log "InfluxDB token is stored in: $SCRIPT_DIR/.env"
  log "Home Assistant reads it from: $DATA_DIR/homeassistant/secrets.yaml"
  warn "HACS still requires ONE UI step: Settings → Devices & services → Add integration → HACS"
}

main "$@"
