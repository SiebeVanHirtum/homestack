#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

# Plain PHP repo to install into ./data/php/app
PHP_REPO_URL="https://github.com/SiebeVanHirtum/HA-Configurator"
PHP_REPO_BRANCH="main"

DOCKER="docker"
COMPOSE=""

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

  while IFS= read -r -d '' f; do hits+=("$f"); done < <(
    grep -RIlZ "$pattern" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
  )

  ((${#hits[@]} == 0)) && return

  warn "Found APT entries pointing to Docker's Ubuntu repo (breaks apt on Debian trixie)."
  for f in "${hits[@]}"; do
    if [[ "$f" == "/etc/apt/sources.list" ]]; then
      warn "Bad entry is in /etc/apt/sources.list (not auto-editing). Remove that line manually, then re-run."
      continue
    fi
    warn "Removing broken repo file: $f"
    sudo rm -f "$f"
  done

  [[ -f /etc/apt/keyrings/docker.gpg ]] && sudo rm -f /etc/apt/keyrings/docker.gpg || true
}

install_docker_and_compose() {
  [[ -r /etc/os-release ]] || err "/etc/os-release not found; cannot detect distro"
  # shellcheck disable=SC1091
  . /etc/os-release

  command -v apt-get &>/dev/null || err "This script currently expects apt-get. Install Docker/Compose manually otherwise."

  [[ "${ID:-}" == "debian" ]] && purge_bad_docker_apt_repo

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
    log "Installing Docker Compose..."
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

file_is_writable() { [[ -e "$1" && -w "$1" ]]; }

write_file() {
  local path="$1"
  local content="$2"
  if [[ -e "$path" ]] && ! file_is_writable "$path"; then
    printf "%s" "$content" | sudo tee "$path" >/dev/null
  else
    printf "%s" "$content" > "$path"
  fi
}

append_file() {
  local path="$1"
  local content="$2"
  if [[ -e "$path" ]] && ! file_is_writable "$path"; then
    printf "%s" "$content" | sudo tee -a "$path" >/dev/null
  else
    printf "%s" "$content" >> "$path"
  fi
}

sed_inplace_delete() {
  local path="$1"
  local expr="$2"
  if [[ -e "$path" ]] && ! file_is_writable "$path"; then
    sudo sed -i "$expr" "$path" || true
  else
    sed -i "$expr" "$path" || true
  fi
}

create_dirs() {
  log "Creating data directories under $DATA_DIR"

  [[ -e "$DATA_DIR" && ! -d "$DATA_DIR" ]] && err "$DATA_DIR exists but is not a directory"

  mkdir -p \
    "$DATA_DIR/homeassistant" \
    "$DATA_DIR/homeassistant/.storage" \
    "$DATA_DIR/nodered" \
    "$DATA_DIR/influxdb" \
    "$DATA_DIR/mosquitto/config" \
    "$DATA_DIR/mosquitto/data" \
    "$DATA_DIR/mosquitto/log" \
    "$DATA_DIR/php/app" \
    "$SCRIPT_DIR/influxdb" \
    "$SCRIPT_DIR/mosquitto" \
    "$SCRIPT_DIR/php"

  [[ -d "$DATA_DIR/homeassistant" ]] || err "$DATA_DIR/homeassistant is not a directory"
}

fix_permissions() {
  log "Fixing permissions for Node-RED and InfluxDB data dirs (uid:gid 1000:1000)"
  sudo chown -R 1000:1000 "$DATA_DIR/nodered" "$DATA_DIR/influxdb" 2>/dev/null || true
  sudo chmod -R u+rwX,g+rwX "$DATA_DIR/nodered" "$DATA_DIR/influxdb" 2>/dev/null || true

  mkdir -p "$DATA_DIR/homeassistant/.storage" || true
  sudo chmod -R a+rwX "$DATA_DIR/homeassistant" 2>/dev/null || true

  # PHP app directory should be writable by container user (www-data)
  sudo chmod -R a+rwX "$DATA_DIR/php/app" 2>/dev/null || true
}

write_php_nginx_conf() {
  # $1 = docroot inside /var/www/html ("" or "public")
  local sub="${1:-}"
  local root="/var/www/html"
  [[ -n "$sub" ]] && root="/var/www/html/$sub"

  write_file "$SCRIPT_DIR/php/nginx.conf" "$(cat <<EOF
server {
    listen 80;
    server_name _;

    root $root;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass php-fpm:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF
)"
}

write_configs() {
  local MOSQ_CONF="$SCRIPT_DIR/mosquitto/mosquitto.conf"
  local MOSQ_DEST="$DATA_DIR/mosquitto/config/mosquitto.conf"
  if [[ -f "$MOSQ_CONF" ]]; then
    log "Using repo mosquitto.conf"
    cp "$MOSQ_CONF" "$MOSQ_DEST"
  elif [[ ! -f "$MOSQ_DEST" ]]; then
    log "Generating default mosquitto.conf"
    write_file "$MOSQ_DEST" "$(cat <<'EOF'
listener 1883
listener 9001
protocol websockets
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF
)"
  fi

  # InfluxDB init-loop fix (entrypoint wrapper)
  local INFLUX_EP="$SCRIPT_DIR/influxdb/entrypoint.sh"
  if [[ ! -f "$INFLUX_EP" ]]; then
    log "Generating influxdb/entrypoint.sh (prevents Influx init loop)"
    write_file "$INFLUX_EP" "$(cat <<'EOF'
#!/bin/sh
set -eu
rm -f /root/.influxdbv2/configs 2>/dev/null || true
rm -rf /root/.influxdbv2 2>/dev/null || true
if [ "$#" -eq 0 ]; then
  set -- influxd
fi
exec /entrypoint.sh "$@"
EOF
)"
  fi

  # PHP-FPM image
  local PHP_DF="$SCRIPT_DIR/php/Dockerfile"
  if [[ ! -f "$PHP_DF" ]]; then
    log "Generating php/Dockerfile"
    write_file "$PHP_DF" "$(cat <<'EOF'
FROM php:8.2-fpm

RUN apt-get update && apt-get install -y \
    git unzip \
  && rm -rf /var/lib/apt/lists/*

# Optional: composer (useful if repo has composer.json, even if you say "no framework")
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
EOF
)"
  fi

  # Default nginx conf (will be adjusted after cloning repo)
  if [[ ! -f "$SCRIPT_DIR/php/nginx.conf" ]]; then
    log "Generating default php/nginx.conf"
    write_php_nginx_conf ""
  fi

  local HA_CONF="$DATA_DIR/homeassistant/configuration.yaml"
  if [[ ! -f "$HA_CONF" ]]; then
    log "Generating default HA configuration.yaml"
    write_file "$HA_CONF" "$(cat <<'EOF'
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
)"
  fi

  local ENV_FILE="$SCRIPT_DIR/.env"
  if [[ ! -f "$ENV_FILE" ]]; then
    log "Generating .env file"
    write_file "$ENV_FILE" "$(cat <<'EOF'
TZ=Europe/Brussels
INFLUXDB_USER=admin
INFLUXDB_PASSWORD=adminpassword
INFLUXDB_ORG=homestack
INFLUXDB_BUCKET=home
INFLUXDB_TOKEN=changeme-token
EOF
)"
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
  [[ -f "$NR_PKG" ]] && cp "$NR_PKG" "$DATA_DIR/nodered/package.json" || true

  local DASH_SRC="$SCRIPT_DIR/homeassistant/dashboards"
  local DASH_DEST="$DATA_DIR/homeassistant/dashboards"
  if [[ -d "$DASH_SRC" ]]; then
    log "Installing HA dashboards from repo"
    mkdir -p "$DASH_DEST"
    cp -r "$DASH_SRC/." "$DASH_DEST/"
  else
    warn "homeassistant/dashboards/ not found in repo — creating placeholder"
    mkdir -p "$DASH_DEST"
    if [[ ! -f "$DASH_DEST/main_dash.yaml" ]]; then
      write_file "$DASH_DEST/main_dash.yaml" "$(cat <<'EOF'
views:
  - title: Home
    cards:
      - type: markdown
        content: "## Welcome to Homestack!\nAdd your cards here."
EOF
)"
    fi
  fi

  local SEC_DEST="$DATA_DIR/homeassistant/secrets.yaml"
  if [[ ! -f "$SEC_DEST" ]]; then
    log "Creating secrets.yaml for HA"
    write_file "$SEC_DEST" "$(cat <<'EOF'
# Add your secrets here
EOF
)"
  fi
}

read_env_var() {
  local key="$1"
  local file="$SCRIPT_DIR/.env"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$1==k{print substr($0, index($0,$2)); exit 0} END{exit 1}' "$file"
}

ensure_influx_token() {
  local bolt="$DATA_DIR/influxdb/influxd.bolt"
  local env_file="$SCRIPT_DIR/.env"
  local tok
  tok="$(read_env_var INFLUXDB_TOKEN || echo "")"

  if [[ -f "$bolt" ]]; then
    log "InfluxDB already initialized (found influxd.bolt). Keeping existing INFLUXDB_TOKEN."
    return
  fi

  if [[ -z "$tok" || "$tok" == "changeme-token" ]]; then
    log "Generating secure InfluxDB token for first-time setup..."
    local new_token=""
    if command -v openssl &>/dev/null; then
      new_token="$(openssl rand -hex 32)"
    else
      new_token="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 64)"
    fi

    if grep -qE '^INFLUXDB_TOKEN=' "$env_file"; then
      if file_is_writable "$env_file"; then
        sed -i "s|^INFLUXDB_TOKEN=.*|INFLUXDB_TOKEN=${new_token}|" "$env_file"
      else
        sudo sed -i "s|^INFLUXDB_TOKEN=.*|INFLUXDB_TOKEN=${new_token}|" "$env_file"
      fi
    else
      append_file "$env_file" $'\n'"INFLUXDB_TOKEN=${new_token}"$'\n'
    fi
  fi
}

ensure_ha_influxdb_config() {
  local ha_conf="$DATA_DIR/homeassistant/configuration.yaml"
  local sec="$DATA_DIR/homeassistant/secrets.yaml"

  local tok org bucket
  tok="$(read_env_var INFLUXDB_TOKEN || echo "")"
  org="$(read_env_var INFLUXDB_ORG || echo "homestack")"
  bucket="$(read_env_var INFLUXDB_BUCKET || echo "home")"

  if ! grep -qE '^[[:space:]]*influxdb:' "$ha_conf"; then
    log "Adding InfluxDB v2 integration to Home Assistant configuration.yaml"
    append_file "$ha_conf" "$(cat <<'EOF'

influxdb:
  api_version: 2
  host: 127.0.0.1
  port: 8086
  ssl: false
  token: !secret influxdb_token
  organization: !secret influxdb_org
  bucket: !secret influxdb_bucket
  tags:
    source: HA
  tags_attributes:
    - friendly_name
  default_measurement: units
EOF
)"
  else
    log "configuration.yaml already has influxdb: block (leaving as-is)."
  fi

  if ! grep -qE '^[[:space:]]*influxdb_token:' "$sec" || grep -qE '^[[:space:]]*influxdb_token:[[:space:]]*("?changeme-token"?)' "$sec"; then
    log "Setting influxdb_token in secrets.yaml from .env"
    sed_inplace_delete "$sec" '/^[[:space:]]*influxdb_token:/d'
    append_file "$sec" "influxdb_token: \"${tok}\""$'\n'
  fi

  if ! grep -qE '^[[:space:]]*influxdb_org:' "$sec"; then
    append_file "$sec" "influxdb_org: \"${org}\""$'\n'
  fi
  if ! grep -qE '^[[:space:]]*influxdb_bucket:' "$sec"; then
    append_file "$sec" "influxdb_bucket: \"${bucket}\""$'\n'
  fi
}

start_stack() {
  [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || err "docker-compose.yml not found next to setup.sh"
  log "Starting stack..."
  cd "$SCRIPT_DIR"

  $COMPOSE up -d --remove-orphans --force-recreate influxdb
  $COMPOSE up -d --remove-orphans

  log "Stack started."
}

wait_for_container_running() {
  local name="$1"
  local timeout="${2:-180}"
  local start_ts now_ts

  start_ts="$(date +%s)"
  while true; do
    if $DOCKER inspect -f '{{.State.Running}}' "$name" >/dev/null 2>&1; then
      local running
      running="$($DOCKER inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")"
      if [[ "$running" == "true" ]]; then
        return 0
      fi
    fi

    now_ts="$(date +%s)"
    if (( now_ts - start_ts > timeout )); then
      return 1
    fi
    sleep 2
  done
}

install_php_site_from_github() {
  local app_dir="$DATA_DIR/php/app"

  log "Installing PHP site from GitHub: $PHP_REPO_URL (branch: $PHP_REPO_BRANCH)"

  if ! wait_for_container_running "php-fpm" 240; then
    warn "php-fpm is not running yet; skipping GitHub clone. Re-run setup.sh once php-fpm is up."
    return
  fi

  # Determine if already installed
  if [[ -f "$app_dir/index.php" || -f "$app_dir/public/index.php" || -f "$app_dir/index.html" || -f "$app_dir/public/index.html" ]]; then
    log "PHP site already present in $app_dir (skipping clone)."
  else
    if [[ -n "$(ls -A "$app_dir" 2>/dev/null || true)" ]]; then
      warn "$app_dir is not empty but no index file found. Not overwriting."
      warn "Empty $app_dir if you want the repo to be cloned fresh."
      return
    fi

    $DOCKER exec php-fpm bash -lc "
      set -euo pipefail
      rm -rf /tmp/php_site_install
      git clone --depth 1 --branch '$PHP_REPO_BRANCH' '$PHP_REPO_URL' /tmp/php_site_install
      cp -a /tmp/php_site_install/. /var/www/html/
      chown -R www-data:www-data /var/www/html || true
    " || err "Failed to clone/copy PHP repo inside php-fpm container."
  fi

  # If repo actually needs composer, do it (harmless for plain PHP repos without composer.json)
  if [[ -f "$app_dir/composer.json" && ! -f "$app_dir/vendor/autoload.php" ]]; then
    log "composer.json found but vendor/autoload.php missing -> running composer install..."
    $DOCKER exec php-fpm bash -lc "
      set -euo pipefail
      cd /var/www/html
      composer install --no-interaction --prefer-dist --optimize-autoloader
    " || err "composer install failed inside php-fpm"
  fi

  # Set nginx docroot automatically: use /public if present
  if [[ -f "$app_dir/public/index.php" || -f "$app_dir/public/index.html" ]]; then
    log "Detected public/ directory -> setting nginx root to /var/www/html/public"
    write_php_nginx_conf "public"
  else
    log "No public/ detected -> setting nginx root to /var/www/html"
    write_php_nginx_conf ""
  fi

  log "Reloading nginx to apply docroot..."
  $DOCKER exec php-nginx nginx -s reload >/dev/null 2>&1 || true
}

restart_homeassistant() {
  log "Restarting Home Assistant to apply config changes..."
  $DOCKER restart homeassistant >/dev/null 2>&1 || true
}

main() {
  log "=== Homestack Setup ==="
  log "Script directory: $SCRIPT_DIR"

  install_docker_and_compose

  create_dirs
  write_configs
  copy_optional_files
  fix_permissions

  ensure_influx_token
  ensure_ha_influxdb_config

  start_stack
  install_php_site_from_github
  restart_homeassistant

  echo ""
  log "=== Setup Complete ==="

  local HOST_IP="127.0.0.1"
  if command -v hostname &>/dev/null && hostname -I &>/dev/null; then
    HOST_IP="$(hostname -I | awk '{print $1}')"
  fi

  echo -e "  Home Assistant : ${GREEN}http://${HOST_IP}:8123${NC}"
  echo -e "  Node-RED       : ${GREEN}http://${HOST_IP}:1880${NC}"
  echo -e "  InfluxDB       : ${GREEN}http://${HOST_IP}:8086${NC}"
  echo -e "  PHP site       : ${GREEN}http://${HOST_IP}:8080${NC}"
  echo -e "  MQTT           : ${GREEN}${HOST_IP}:1883${NC}"
}

main "$@"
