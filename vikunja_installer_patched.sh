#!/bin/bash
# ==============================================================================
# Vikunja Installer & Manager (interactive) - Split/Combined Switchable
# Debian 12 - MariaDB - Reverse Proxy friendly
# v2.0 (adds: switch combined<->split, FE deploy from ZIP/dir, FE build from git)
# ==============================================================================
set -euo pipefail

# --- Globals ------------------------------------------------------------------
STATE_FILE="/etc/vikunja/.vikunja_install_state"

API_BIN="/usr/local/bin/vikunja"
API_USER="vikunja"
API_GROUP="vikunja"
API_DATA_DIR="/var/lib/vikunja"
API_ETC_DIR="/etc/vikunja"
API_SERVICE_COMBINED="vikunja"
API_SERVICE_SPLIT="vikunja-api"
API_PORT="3456"

FRONTEND_DIR="/var/www/vikunja"
FRONTEND_CFG="${FRONTEND_DIR}/config.json"

NGINX_SITE="/etc/nginx/sites-available/vikunja.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/vikunja.conf"

DEFAULT_API_VER="v0.24.4"
DEFAULT_FE_VER="v0.24.4"

# --- UI helpers ----------------------------------------------------------------
b() { echo -e "\n\033[1m$*\033[0m"; }
info() { echo -e "[\033[34mi\033[0m] $*"; }
ok() { echo -e "[\033[32mok\033[0m] $*"; }
warn() { echo -e "[\033[33m!\033[0m] $*"; }
err() { echo -e "[\033[31merr\033[0m] $*" >&2; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

# --- System setup --------------------------------------------------------------
install_packages() {
  info "System-Update & Basis-Pakete..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y curl wget tar unzip ca-certificates gnupg lsb-release jq \
                     rsync nginx mariadb-server git
  ok "Pakete installiert."
}

ensure_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    info "Nginx ist nicht installiert – installiere..."
    apt-get update -y
    apt-get install -y nginx
    ok "Nginx installiert."
  fi
}

ensure_users_dirs() {
  id -u "${API_USER}" >/dev/null 2>&1 || useradd --system --home "${API_DATA_DIR}" --shell /usr/sbin/nologin "${API_USER}"
  mkdir -p "${API_DATA_DIR}" "${API_ETC_DIR}" "${FRONTEND_DIR}"
  chown -R "${API_USER}:${API_GROUP:-${API_USER}}" "${API_DATA_DIR}" || true
  chown -R www-data:www-data "${FRONTEND_DIR}"
}

# --- Download helpers ----------------------------------------------------------
detect_arch() {
  local arch="amd64"
  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    armhf) arch="armv7" ;;
    *) warn "Unbekannte Architektur, versuche amd64." ; arch="amd64" ;;
  esac
  echo "${arch}"
}

download_api_release() {
  local ver="$1"
  local arch; arch="$(detect_arch)"
  local zipname="vikunja-v${ver#v}-linux-${arch}-full.zip"
  local url="https://dl.vikunja.io/vikunja/${ver#v}/${zipname}"
  info "Lade API/combined Binary: ${url}"
  cd /tmp
  wget -q --show-progress "${url}"
  unzip -o -q "${zipname}" -d /usr/local/bin/
  chmod +x /usr/local/bin/vikunja
  ok "vikunja Binary installiert nach /usr/local/bin/vikunja"
}

download_frontend_release() {
  local ver="$1"
  local url="https://dl.vikunja.io/frontend/${ver#v}/frontend.zip"
  info "Lade Frontend Release ${ver}: ${url}"
  cd /tmp
  wget -q --show-progress -O frontend.zip "${url}"
  deploy_frontend_zip "/tmp/frontend.zip"
}

# --- Frontend deploy/build -----------------------------------------------------
write_frontend_config() {
  local api_subpath="${1:-/api/v1}"
  mkdir -p "$(dirname "${FRONTEND_CFG}")"
  cat > "${FRONTEND_CFG}" <<EOF
{ "api": "${api_subpath}" }
EOF
  ok "Frontend config.json geschrieben (${api_subpath})"
}

deploy_frontend_zip() {
  local zipfile="$1"
  ensure_users_dirs
  info "Entpacke Frontend ZIP nach ${FRONTEND_DIR} ..."
  tmpdir="$(mktemp -d)"
  unzip -q "${zipfile}" -d "${tmpdir}"
  rsync -a --delete "${tmpdir}/" "${FRONTEND_DIR}/"
  rm -rf "${tmpdir}"
  chown -R www-data:www-data "${FRONTEND_DIR}"
  write_frontend_config "/api/v1"
  ok "Frontend deployed."
}

deploy_frontend_dir() {
  local distdir="$1"
  ensure_users_dirs
  info "Deploy Frontend aus Ordner ${distdir} → ${FRONTEND_DIR} ..."
  rsync -a --delete "${distdir}/" "${FRONTEND_DIR}/"
  chown -R www-data:www-data "${FRONTEND_DIR}"
  write_frontend_config "/api/v1"
  ok "Frontend deployed."
}

node_setup() {
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  corepack enable >/dev/null 2>&1 || npm i -g corepack
  corepack prepare pnpm@latest --activate
}

build_frontend_from_git() {
  local repo="$1" ref="${2:-}"
  ensure_users_dirs
  node_setup
  local src="/tmp/vikunja-src-$$"
  rm -rf "${src}"
  git clone --depth 1 "${repo}" "${src}"
  if [ -n "${ref}" ]; then
    git -C "${src}" fetch --depth 1 origin "${ref}" || true
    git -C "${src}" checkout -q "${ref}" || true
  fi
  pushd "${src}/frontend" >/dev/null
  pnpm install
  pnpm run build
  popd >/dev/null
  rsync -a --delete "${src}/frontend/dist/" "${FRONTEND_DIR}/"
  chown -R www-data:www-data "${FRONTEND_DIR}"
  write_frontend_config "/api/v1"
  rm -rf "${src}"
  ok "Frontend aus Source gebaut & deployed."
}

# --- API: systemd services -----------------------------------------------------
write_api_split_service() {
  cat > /etc/systemd/system/${API_SERVICE_SPLIT}.service <<'UNIT'
[Unit]
Description=Vikunja API (split)
After=network.target mariadb.service

[Service]
User=vikunja
Group=vikunja
ExecStart=/usr/local/bin/vikunja
Environment=VIKUNJA_CONFIG=/etc/vikunja/config.yml
WorkingDirectory=/var/lib/vikunja
Restart=on-failure
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  ok "systemd Service (${API_SERVICE_SPLIT}) geschrieben."
}

# --- Nginx config --------------------------------------------------------------
write_nginx_same_origin() {
  local server_name="$1"
  ensure_nginx
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat > "${NGINX_SITE}" <<EOF
server {
  listen 80;
  server_name ${server_name};

  root ${FRONTEND_DIR};
  index index.html;

  location /api/ {
    proxy_pass http://127.0.0.1:${API_PORT}/api/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location / {
    try_files \$uri /index.html;
  }

  location ~* \.(?:js|css|woff2?|ttf|png|jpg|svg)$ {
    expires 30d;
    access_log off;
    try_files \$uri /index.html;
  }
}
EOF

  ln -sf "${NGINX_SITE}" "${NGINX_SITE_LINK}"
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  ok "Nginx konfiguriert (HTTP-only, TLS extern via Reverse Proxy)."
}
}

# --- Config helpers ------------------------------------------------------------
write_default_config_if_missing() {
  if [ ! -f "${API_ETC_DIR}/config.yml" ]; then
    cat > "${API_ETC_DIR}/config.yml" <<EOF
service:
  publicurl: https://example.org
  interface: 0.0.0.0
  port: ${API_PORT}

database:
  type: mysql
  host: 127.0.0.1:3306
  user: vikunja
  password: vikunja
  database: vikunja

files:
  basepath: ${API_DATA_DIR}

# cors:
#   enabled: false
EOF
    ok "Default /etc/vikunja/config.yml erstellt (bitte anpassen!)."
  fi
}

# --- State helpers -------------------------------------------------------------
save_state() {
  mkdir -p "$(dirname "${STATE_FILE}")"
  cat > "${STATE_FILE}" <<EOF
MODE='${1}'
SERVER_NAME='${2}'
EOF
}

load_state() {
  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${STATE_FILE}"
  fi
}

is_running() {
  systemctl is-active --quiet "$1"
}

# --- Actions -------------------------------------------------------------------
install_combined() {
  b "Installiere kombinierte Binary-Variante (API+FE im einen Prozess)..."
  install_packages
  ensure_users_dirs
  download_api_release "${DEFAULT_API_VER}"
  write_default_config_if_missing
  systemctl stop ${API_SERVICE_SPLIT} || true
  systemctl disable ${API_SERVICE_SPLIT} || true
  # Launch combined binary as 'vikunja' service if exists or create minimal unit
  if systemctl list-unit-files | grep -q "^${API_SERVICE_COMBINED}\\.service"; then
    systemctl enable --now ${API_SERVICE_COMBINED}
  else
    cat > /etc/systemd/system/${API_SERVICE_COMBINED}.service <<'UNIT'
[Unit]
Description=Vikunja (combined)
After=network.target mariadb.service

[Service]
User=vikunja
Group=vikunja
ExecStart=/usr/local/bin/vikunja
Environment=VIKUNJA_CONFIG=/etc/vikunja/config.yml
WorkingDirectory=/var/lib/vikunja
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now ${API_SERVICE_COMBINED}
  fi
  ok "Kombinierte Variante aktiv."
  save_state "COMBINED" "${SERVER_NAME:-example.org}"
}

switch_to_split() {
  b "Wechsel: Kombi → Getrennt (API + Frontend, Same-Origin)"
  install_packages
  ensure_users_dirs
  write_default_config_if_missing
  write_api_split_service
  systemctl stop ${API_SERVICE_COMBINED} || true
  systemctl enable --now ${API_SERVICE_SPLIT}
  write_nginx_same_origin "${SERVER_NAME:-example.org}"
  ok "Split-Modus aktiv. Frontend kann separat deployed/aktualisiert werden."
  save_state "SPLIT" "${SERVER_NAME:-example.org}"
}

switch_to_combined() {
  b "Wechsel: Getrennt → Kombi"
  systemctl stop ${API_SERVICE_SPLIT} || true
  systemctl disable ${API_SERVICE_SPLIT} || true
  install_combined
  ok "Zurück auf kombinierte Installation."
}

update_frontend_from_zip() {
  read -rp "Pfad zur Frontend-ZIP-Datei: " zip
  [ -f "$zip" ] || { err "ZIP nicht gefunden: $zip"; exit 1; }
  deploy_frontend_zip "$zip"
}

update_frontend_from_dir() {
  read -rp "Pfad zum dist/-Ordner: " dir
  [ -d "$dir" ] || { err "Ordner nicht gefunden: $dir"; exit 1; }
  deploy_frontend_dir "$dir"
}

build_frontend_flow() {
  read -rp "Git-Repo (Default https://code.vikunja.io/vikunja): " repo
  repo="${repo:-https://code.vikunja.io/vikunja}"
  read -rp "Branch/Tag (leer = default): " ref
  build_frontend_from_git "$repo" "$ref"
}

configure_nginx_domain() {
  read -rp "FQDN/Server-Name (z.B. vikunja.example.org): " SERVER_NAME
  [ -z "${SERVER_NAME}" ] && { err "Server-Name darf nicht leer sein."; exit 1; }
  write_nginx_same_origin "${SERVER_NAME}"
  save_state "${MODE:-UNKNOWN}" "${SERVER_NAME}"
}

# --- Menu ----------------------------------------------------------------------
main_menu() {
  load_state
  b "Vikunja Installer/Manager"
  echo "Aktueller Modus: ${MODE:-unbekannt}    Domain: ${SERVER_NAME:-(nicht gesetzt)}"
  cat <<'MENU'

  [1] Installiere kombinierte Binary-Variante
  [2] Wechsle zu getrenntem Betrieb (API + Frontend)
  [3] Wechsle zurück zur kombinierten Variante

  --- Frontend verwalten (nur SPLIT sinnvoll) ---
  [4] Frontend aktualisieren aus ZIP
  [5] Frontend aktualisieren aus dist/-Ordner
  [6] Frontend aus Git-Source bauen & deployen (pnpm)

  --- Nginx / Domain ---
  [7] Nginx auf Same-Origin konfigurieren / Domain setzen

  [0] Beenden
MENU
  read -rp "Auswahl: " choice
  case "$choice" in
    1) install_combined ;;
    2) switch_to_split ;;
    3) switch_to_combined ;;
    4) update_frontend_from_zip ;;
    5) update_frontend_from_dir ;;
    6) build_frontend_flow ;;
    7) configure_nginx_domain ;;
    0) exit 0 ;;
    *) echo "Ungültig" ;;
  esac
}

# --- Entry ---------------------------------------------------------------------
require_root
main_menu
