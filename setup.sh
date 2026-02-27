#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Homestack Setup Script (repo-friendly)
# - Assumes this script is run from a git-cloned repo
# - Reads optional files relative to the script directory
# - Works on Debian (incl. trixie) by installing docker.io from Debian repos
# - Uses service names for inter-container networking (mosquitto, influxdb, etc.)
# - Provides host access from containers via host.docker.internal (compose extra_hosts)
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
DOCKER="docker" # will be set by detect_docker_cmd()

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

detect_docker_cmd() {
  # Prefer plain docker; fall back to sudo docker if group membership isn't active yet
  if command -v docker &>/dev/null && docker ps &>/dev/null; then
    DOCKER="docker"
    return
  fi
  if command -v docker &>/dev/null; then
    DOCKER="sudo docker"
    return
  fi
  DOCKER="docker"
}

require_compose() {
  if ! $DOCKER compose version &>/dev/null; then
    err "Docker Compose plugin not found. Install 'docker-compose-plugin' (Debian/Ubuntu) then re-run."
  fi
}

# ─────────────────────────────────────────────
# 1. Install Docker if missing (Debian-safe)
# ─────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
    detect_docker_cmd
    return
  fi

  log "Installing Docker..."

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    err "/etc/os-release not found; cannot detect distro"
  fi

  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq

    if [[ "${ID:-}" == "debian" ]]; then
      # Debian (incl. trixie/testing): use Debian packages (reliable)
      sudo apt-get install -y docker.io docker-compose-plugin
      sudo systemctl enable --now docker

    elif [[ "${ID:-}" == "ubuntu" ]]; then
      # Ubuntu: Docker CE from docker.com repo
      sudo apt-get install -y ca-certificates curl gnupg lsb-release
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

      sudo apt-get update -qq
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      sudo systemctl enable --now docker

    else
      err "apt-get detected but unsupported distro ID='${ID:-unknown}'. Install Docker manually."
    fi

  elif command -v dnf &>/dev/null; then
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl enable --now docker

  elif command -v pacman &>/dev/null; then
    sudo pacman -Sy --noconfirm docker docker-compose
    sudo systemctl enable --now docker

  else
    err "Unsupported package manager. Install Docker manually: https://docs.docker.com/engine/install/"
  fi

  sudo usermod -aG docker "$USER"
  warn "Added '$USER' to the 'docker' group. You may need to log out/in for non-sudo docker."

  detect_docker_cmd
}

# ─────────────────────────────────────────────
# 2. Create data directories
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 3. Write generated config files (only if missing)
# ─────────────────────────────────────────────
write_configs() {
  # ── Mosquitto ─────────────────────────────
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

  # ── Laravel Nginx vhost ───────────────────
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

  # ── Laravel Dockerfile ─────────────────────
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

  # ── Home Assistant configuration.yaml ──────
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

  # ── .env file ──────────────────────────────
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

# ─────────────────────────────────────────────
# 4. Copy optional repo files if they exist
# ─────────────────────────────────────────────
copy_optional_files() {
  # ── Node-RED flows ─────────────────────────
  local NR_SRC="$SCRIPT_DIR/nodered/flows.json"
  local NR_DEST="$DATA_DIR/nodered/flows.json"
  if [[ -f "$NR_SRC" ]]; then
    log "Installing Node-RED flows from repo"
    cp "$NR_SRC" "$NR_DEST"
  else
    warn "nodered/flows.json not found in repo — Node-RED will start empty"
  fi

  # ── Node-RED extra packages ────────────────
  local NR_PKG="$SCRIPT_DIR/nodered/package.json"
  if [[ -f "$NR_PKG" ]]; then
    log "Installing Node-RED package.json from repo"
    cp "$NR_PKG" "$DATA_DIR/nodered/package.json"
  fi

  # ── HA dashboards ──────────────────────────
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

  # ── HA secrets.yaml ────────────────────────
  local SEC_DEST="$DATA_DIR/homeassistant/secrets.yaml"
  if [[ ! -f "$SEC_DEST" ]]; then
    log "Creating empty secrets.yaml for HA"
    echo "# Add your secrets here" > "$SEC_DEST"
  fi
}

# ─────────────────────────────────────────────
# 5. Start the stack
# ─────────────────────────────────────────────
start_stack() {
  [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || err "docker-compose.yml not found next to setup.sh"

  log "Starting Docker Compose stack..."
  cd "$SCRIPT_DIR"
  require_compose
  $DOCKER compose up -d
  log "Stack started."
}

# ─────────────────────────────────────────────
# 6. Initialize Laravel (first run only)
# ─────────────────────────────────────────────
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
  " || warn "Laravel init failed (container may still be building). You can re-run setup.sh later."
}

# ─────────────────────────────────────────────
# 7. Install HACS
# ─────────────────────────────────────────────
install_hacs() {
  local HACS_MARKER="$DATA_DIR/homeassistant/custom_components/hacs"
  if [[ -d "$HACS_MARKER" ]]; then
    log "HACS already installed, skipping."
    return
  fi

  log "Installing HACS..."
  # Try wget; fall back to curl (some images may have one but not the other)
  $DOCKER exec homeassistant sh -c \
    "(command -v wget >/dev/null 2>&1 && wget -qO- https://get.hacs.xyz | sh) || (command -v curl >/dev/null 2>&1 && curl -fsSL https://get.hacs.xyz | sh)" \
    || warn "HACS install failed — install manually later."

  log "Restarting Home Assistant to load HACS..."
  $DOCKER restart homeassistant || true
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
main() {
  log "=== Homestack Setup ==="
  log "Script directory: $SCRIPT_DIR"

  install_docker
  detect_docker_cmd
  create_dirs
  write_configs
  copy_optional_files
  start_stack
  init_laravel
  install_hacs

  echo ""
  log "=== Setup Complete ==="

  # Best-effort "what IP do I browse to?"
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
  warn "InfluxDB credentials are in .env — change them!"
  warn "HACS: Go to HA → Settings → Integrations → Add → HACS to finish setup."
  warn "Node-RED: use service names like 'mosquitto' and 'influxdb' (not 127.0.0.1)."
  warn "From Node-RED to Home Assistant (host network): use 'host.docker.internal:8123'."
}

main "$@"
