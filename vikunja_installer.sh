#!/bin/bash
# ==============================================================================
# Vikunja Installer & Manager (interactive)
# Debian 12 - MariaDB - Reverse Proxy friendly
# v1.0
# ==============================================================================

set -euo pipefail

# --- Globals ---
STATE_FILE=".vikunja_install_state"
API_BIN="/usr/local/bin/vikunja"
API_USER="vikunja"
API_GROUP="vikunja"
API_DATA_DIR="/var/lib/vikunja"
API_ETC_DIR="/etc/vikunja"
API_CFG="${API_ETC_DIR}/config.yml"
API_SERVICE="/etc/systemd/system/vikunja.service"

FRONTEND_DIR="/var/www/vikunja"
FRONTEND_CFG="${FRONTEND_DIR}/config.json"

SERVICES=("mariadb.service" "vikunja.service")

# Colors
b() { printf "\033[1m%s\033[0m\n" "$*"; }
ok() { echo "✅ $*"; }
info() { echo "→ $*"; }
warn() { echo "⚠️  $*"; }
err() { echo "❌ $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then err "Bitte als root ausführen."; exit 1; fi
}

# --- Install steps ---
install_packages() {
  info "System-Update & Pakete..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y curl wget tar unzip ca-certificates gnupg lsb-release \
                     mariadb-server
  ok "Pakete installiert."
}

prepare_db() {
  local db="$1" user="$2" pass="$3"
  info "MariaDB: Datenbank & Benutzer anlegen..."
  systemctl enable --now mariadb
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
  ok "MariaDB konfiguriert."
}

create_system_user() {
  if ! id -u "${API_USER}" >/dev/null 2>&1; then
    info "Systembenutzer ${API_USER} anlegen..."
    useradd --system --home "${API_DATA_DIR}" --shell /usr/sbin/nologin "${API_USER}"
  fi
  mkdir -p "${API_DATA_DIR}" "${API_ETC_DIR}"
  chown -R "${API_USER}:${API_GROUP}" "${API_DATA_DIR}" || chown -R "${API_USER}:${API_USER}" "${API_DATA_DIR}" || true
  ok "Systembenutzer & Verzeichnisse vorbereitet."
}

download_api() {
  local ver="$1" arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "Unbekannte Architektur ${arch}, versuche amd64."; arch="amd64" ;;
  esac

  info "Lade vikunja-api ${ver} (${arch})..."
  cd /tmp
  wget -q --show-progress "https://dl.vikunja.io/api/${ver}/vikunja-${ver}-linux-${arch}.tar.gz"
  tar -xzf "vikunja-${ver}-linux-${arch}.tar.gz"
  install -m 0755 vikunja "${API_BIN}"
  rm -f "vikunja-${ver}-linux-${arch}.tar.gz" vikunja
  ok "vikunja-api installiert: ${API_BIN}"
}

write_api_config() {
  local public_url="$1" dbname="$2" dbuser="$3" dbpass="$4" allow_origin="$5"
  info "Schreibe ${API_CFG}..."
  cat > "${API_CFG}" <<EOF
service:
  # Öffentliche URL der API (wichtig für Links/E-Mails)
  publicurl: "${public_url}"
  # Interface/Port: hinter Reverse Proxy reicht localhost
  interface: "127.0.0.1:3456"

log:
  level: "info"

database:
  type: "mysql"
  host: "127.0.0.1:3306"
  user: "${dbuser}"
  password: "${dbpass}"
  database: "${dbname}"

cors:
  enabled: true
  # Erlaube Aufrufe vom Frontend (Domain ohne Slash!)
  alloworigins:
    - "${allow_origin}"

auth:
  # Lokale Logins erlauben (Standard)
  local:
    enabled: true
EOF
  ok "API-Konfiguration geschrieben."
}

write_systemd_service() {
  info "Systemd-Service anlegen..."
  cat > "${API_SERVICE}" <<'EOF'
[Unit]
Description=Vikunja API
After=network.target mariadb.service
Wants=mariadb.service

[Service]
User=vikunja
Group=vikunja
ExecStart=/usr/local/bin/vikunja
WorkingDirectory=/var/lib/vikunja
Environment=VIKUNJA_CONFIG=/etc/vikunja/config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

# Sicherheit (optional, aber sinnvoll)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now vikunja
  ok "vikunja.service aktiv."
}

download_frontend() {
  local ver="$1"
  info "Lade vikunja-frontend ${ver}..."
  mkdir -p "${FRONTEND_DIR}"
  cd /tmp
  wget -q --show-progress "https://dl.vikunja.io/frontend/${ver}/frontend-${ver}.zip"
  unzip -oq "frontend-${ver}.zip" -d "${FRONTEND_DIR}"
  rm -f "frontend-${ver}.zip"
  ok "Frontend nach ${FRONTEND_DIR} installiert."
}

write_frontend_config() {
  local api_url="$1"
  info "Schreibe Frontend config.json..."
  cat > "${FRONTEND_CFG}" <<EOF
{ "api": "${api_url}" }
EOF
  ok "Frontend-Konfiguration geschrieben."
}

cleanup_install() {
  local db="$1" dbuser="$2"
  warn "Bereinige vorhandene Vikunja-Installation..."
  systemctl stop vikunja 2>/dev/null || true
  systemctl disable vikunja 2>/dev/null || true
  rm -f "${API_SERVICE}" && systemctl daemon-reload || true

  mysql -e "DROP DATABASE IF EXISTS \`${db}\`;" || true
  mysql -e "DROP USER IF EXISTS '${dbuser}'@'localhost';" || true
  mysql -e "FLUSH PRIVILEGES;" || true

  rm -rf "${API_BIN}" "${API_ETC_DIR}" "${API_DATA_DIR}" "${FRONTEND_DIR}" || true

  id "${API_USER}" >/dev/null 2>&1 && userdel -r "${API_USER}" 2>/dev/null || true
  rm -f "${STATE_FILE}"
  ok "Bereinigung abgeschlossen."
}

service_status()  { systemctl status "${SERVICES[@]}"; }
service_start()   { systemctl start  "${SERVICES[@]}"; ok "Dienste gestartet."; }
service_stop()    { systemctl stop   "${SERVICES[@]}"; ok "Dienste gestoppt."; }
service_restart() { systemctl restart "${SERVICES[@]}"; ok "Dienste neu gestartet."; }

# --- Main installation flow ---
run_install() {
  # Prompts
  read -p "Vikunja API-Version [v0.24.4 o.ä.] (Default: v0.24.4): " API_VER_IN
  API_VER=${API_VER_IN:-v0.24.4}
  read -p "Vikunja Frontend-Version (passend zur API) (Default: v0.24.4): " FE_VER_IN
  FE_VER=${FE_VER_IN:-v0.24.4}

  read -p "API-URL (z.B. https://api.example.de): " API_URL
  [ -z "${API_URL}" ] && { err "API-URL darf nicht leer sein."; exit 1; }

  read -p "Frontend-URL (z.B. https://todo.example.de): " FE_URL
  [ -z "${FE_URL}" ] && { err "Frontend-URL darf nicht leer sein."; exit 1; }

  read -p "MariaDB-DB-Name [vikunja]: " DB_NAME_IN
  DB_NAME=${DB_NAME_IN:-vikunja}
  read -p "MariaDB-User [vikunja]: " DB_USER_IN
  DB_USER=${DB_USER_IN:-vikunja}

  read -s -p "MariaDB-Passwort (leer = generieren): " DB_PASS
  if [ -z "${DB_PASS}" ]; then
    DB_PASS=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
    echo
    b "Generiertes DB-Passwort: ${DB_PASS}"
  else
    echo
  fi

  echo
  b "Starte Installation…"

  install_packages
  prepare_db "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
  create_system_user
  download_api "${API_VER}"
  write_api_config "${API_URL}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${FE_URL}"
  write_systemd_service
  download_frontend "${FE_VER}"
  write_frontend_config "${API_URL}/api/v1"

  # Save state
  cat > "${STATE_FILE}" <<EOF
API_VER='${API_VER}'
FE_VER='${FE_VER}'
API_URL='${API_URL}'
FE_URL='${FE_URL}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
EOF

  echo
  b "🎉 Vikunja ist bereit!"
  echo "API  läuft intern auf: 127.0.0.1:3456"
  echo "API  öffentlich unter:  ${API_URL}"
  echo "Frontend unter:         ${FE_URL}"
  echo
  echo "⚙️  Reverse-Proxy Hinweise:"
  echo "  - Proxy ${API_URL}  →  http://127.0.0.1:3456 (z.B. / und /api/v1 passt ohnehin)"
  echo "  - Frontend ${FE_URL} dient statische Dateien aus ${FRONTEND_DIR}"
  echo "  - CORS erlaubt ${FE_URL} in der API-Konfiguration"
  echo
  ok "Fertig."
}

# --- Menu / Manager ---
main_menu() {
  require_root

  if [ -f "${STATE_FILE}" ]; then
    # Load state
    # shellcheck disable=SC1090
    . "${STATE_FILE}"

    echo
    b "================= VIKUNJA MANAGER ================="
    echo "API: ${API_URL}  |  Frontend: ${FE_URL}"
    echo "Versionen: API ${API_VER} / Frontend ${FE_VER}"
    echo
    echo "--- Dienste ---"
    echo "  1) Status anzeigen"
    echo "  2) Dienste starten"
    echo "  3) Dienste stoppen"
    echo "  4) Dienste neustarten"
    echo "--- Installation & Wartung ---"
    echo "  5) Neuinstallation (DB & Dateien werden ERSETZT)"
    echo "  6) Vollständig deinstallieren (ALLES löschen)"
    echo "  7) Abbrechen"
    read -p "Bitte wählen [1-7]: " choice

    case "$choice" in
      1) service_status ;;
      2) service_start ;;
      3) service_stop ;;
      4) service_restart ;;
      5)
        read -p "Sicher? (ja/nein): " c
        if [ "$c" = "ja" ]; then
          cleanup_install "${DB_NAME}" "${DB_USER}"
          run_install
        else
          echo "Abbruch."
        fi
        ;;
      6)
        read -p "WIRKLICH ALLES löschen? (ja/nein): " c
        if [ "$c" = "ja" ]; then
          cleanup_install "${DB_NAME}" "${DB_USER}"
          ok "Vikunja komplett entfernt."
        else
          echo "Abbruch."
        fi
        ;;
      7) echo "Tschüss."; exit 0 ;;
      *) err "Ungültige Auswahl."; exit 1 ;;
    esac
  else
    b "Willkommen zum Vikunja-Installer."
    run_install
  fi
}

main_menu
