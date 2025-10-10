#!/bin/bash
# ==============================================================================
# Vikunja Installer & Manager (interactive)
# Debian 12 - MariaDB - Reverse Proxy friendly
# v1.3  (fix: robust ZIP extraction for FULL builds)
# ==============================================================================
set -euo pipefail

# --- Globals ------------------------------------------------------------------
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

DEFAULT_API_VER="v0.24.4"
DEFAULT_FE_VER="v0.24.4"

SERVICES=("mariadb.service" "vikunja.service")

# --- UI helpers ---------------------------------------------------------------
b()   { printf "\033[1m%s\033[0m\n" "$*"; }
ok()  { echo "✅ $*"; }
info(){ echo "→ $*"; }
warn(){ echo "⚠️  $*"; }
err() { echo "❌ $*" >&2; }

require_root() { [ "$(id -u)" -eq 0 ] || { err "Bitte als root ausführen."; exit 1; }; }

# --- Detect existing install (even if state file is missing) -------------------
is_installed() {
  if [ -f "${API_CFG}" ] || [ -f "${API_SERVICE}" ] || command -v vikunja >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# --- System packages -----------------------------------------------------------
install_packages() {
  info "System-Update & Basis-Pakete..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y curl wget tar unzip ca-certificates gnupg lsb-release \
                     jq mariadb-server
  ok "Pakete installiert."
}

# --- MariaDB -------------------------------------------------------------------
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

# --- System user / dirs --------------------------------------------------------
create_system_user() {
  if ! id -u "${API_USER}" >/dev/null 2>&1; then
    info "Systembenutzer ${API_USER} anlegen..."
    useradd --system --home "${API_DATA_DIR}" --shell /usr/sbin/nologin "${API_USER}"
  fi
  mkdir -p "${API_DATA_DIR}" "${API_ETC_DIR}"
  chown -R "${API_USER}:${API_GROUP}" "${API_DATA_DIR}" 2>/dev/null || chown -R "${API_USER}:${API_USER}" "${API_DATA_DIR}" || true
  ok "Systembenutzer & Verzeichnisse vorbereitet."
}

# --- Download API (FULL zip includes frontend) --------------------------------
download_api() {
  local ver="$1" arch zipname url workdir binpath
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "Unbekannte Architektur $(uname -m), nehme amd64."; arch="amd64" ;;
  esac

  # FULL-Build: API liefert Frontend mit aus (optional trotzdem separates Frontend möglich)
  zipname="vikunja-v${ver#v}-linux-${arch}-full.zip"
  url="https://dl.vikunja.io/vikunja/${ver#v}/${zipname}"

  info "Lade ${url} ..."
  cd /tmp
  wget -q --show-progress "${url}"

  info "Entpacke ${zipname} ..."
  workdir="$(mktemp -d /tmp/vikunja_full_XXXX)"
  unzip -oq "${zipname}" -d "${workdir}"

  # Binary robust finden (egal wo sie im ZIP liegt)
  binpath="$(find "${workdir}" -type f -name vikunja -print -quit || true)"
  if [ -z "${binpath}" ]; then
    err "Konnte die Vikunja-Binary im ZIP nicht finden."
    ls -la "${workdir}" || true
    exit 1
  fi
  chmod +x "${binpath}"
  install -m 0755 "${binpath}" "${API_BIN}"

  rm -f "${zipname}"
  rm -rf "${workdir}"
  ok "vikunja installiert: ${API_BIN}"
}

# --- Write API config ----------------------------------------------------------
write_api_config() {
  local public_url="$1" dbname="$2" dbuser="$3" dbpass="$4" fe_origin="$5" mode="$6"
  # mode: FULL or SEPARATE
  info "Schreibe ${API_CFG}..."
  mkdir -p "$(dirname "${API_CFG}")"
  cat > "${API_CFG}" <<EOF
service:
  # Öffentliche URL der API (wichtig für Links/E-Mails)
  publicurl: "${public_url}"
  # API lauscht nur lokal; Reverse Proxy übernimmt TLS/Host
  interface: "127.0.0.1:3456"

log:
  level: "info"

database:
  type: "mysql"
  host: "127.0.0.1:3306"
  user: "${dbuser}"
  password: "${dbpass}"
  database: "${dbname}"

# CORS nur nötig, wenn Frontend auf separater Domain
cors:
  enabled: $([ "${mode}" = "SEPARATE" ] && echo true || echo false)
  alloworigins:
    - "${fe_origin}"
EOF
  ok "API-Konfiguration geschrieben."
}

# --- systemd service -----------------------------------------------------------
write_systemd_service() {
  info "Richte systemd-Service ein..."
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

# --- Frontend (separat) --------------------------------------------------------
download_frontend() {
  local ver="$1" fezip="vikunja-frontend-${ver#v}.zip" url="https://dl.vikunja.io/frontend/${fezip}"
  info "Lade Frontend: ${url} ..."
  mkdir -p "${FRONTEND_DIR}"
  cd /tmp
  wget -q --show-progress "${url}"
  unzip -oq "${fezip}" -d "${FRONTEND_DIR}"
  rm -f "${fezip}"
  ok "Frontend nach ${FRONTEND_DIR} installiert."
}

write_frontend_config() {
  local api_url="$1"
  info "Schreibe Frontend config.json..."
  mkdir -p "${FRONTEND_DIR}"
  cat > "${FRONTEND_CFG}" <<EOF
{ "api": "${api_url}" }
EOF
  ok "Frontend config.json geschrieben."
}

# --- Services helper -----------------------------------------------------------
service_status()  { systemctl --no-pager status "${SERVICES[@]}" || true; }
service_start()   { systemctl start  "${SERVICES[@]}"; ok "Dienste gestartet."; }
service_stop()    { systemctl stop   "${SERVICES[@]}"; ok "Dienste gestoppt."; }
service_restart() { systemctl restart "${SERVICES[@]}"; ok "Dienste neu gestartet."; }

# --- Cleanup / Uninstall -------------------------------------------------------
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

# --- Install flow --------------------------------------------------------------
run_install() {
  echo
  b "Installationsmodus wählen:"
  echo "  1) FULL     – API liefert Frontend mit (eine Domain, einfacher)"
  echo "  2) SEPARATE – getrennte Domains für API & Frontend"
  read -rp "Auswahl [1/2] (Default 1): " MODE_IN
  [ -z "${MODE_IN}" ] && MODE_IN=1
  case "$MODE_IN" in
    1) MODE="FULL" ;;
    2) MODE="SEPARATE" ;;
    *) err "Ungültige Auswahl."; exit 1 ;;
  esac

  read -rp "Vikunja API-Version (Default: ${DEFAULT_API_VER}): " API_VER_IN
  API_VER=${API_VER_IN:-${DEFAULT_API_VER}}

  if [ "${MODE}" = "SEPARATE" ]; then
    read -rp "Vikunja Frontend-Version (Default: ${DEFAULT_FE_VER}): " FE_VER_IN
    FE_VER=${FE_VER_IN:-${DEFAULT_FE_VER}}
  else
    FE_VER="(from full binary)"
  fi

  read -rp "API-URL (z.B. https://api.example.de): " API_URL
  [ -z "${API_URL}" ] && { err "API-URL darf nicht leer sein."; exit 1; }

  if [ "${MODE}" = "SEPARATE" ]; then
    read -rp "Frontend-URL (z.B. https://todo.example.de): " FE_URL
    [ -z "${FE_URL}" ] && { err "Frontend-URL darf nicht leer sein."; exit 1; }
  else
    FE_URL="${API_URL}" # gleiche Origin
  fi

  read -rp "MariaDB-DB-Name [vikunja]: " DB_NAME_IN
  DB_NAME=${DB_NAME_IN:-vikunja}
  read -rp "MariaDB-User [vikunja]: " DB_USER_IN
  DB_USER=${DB_USER_IN:-vikunja}

  read -srp "MariaDB-Passwort (leer = generieren): " DB_PASS
  if [ -z "${DB_PASS}" ]; then
    DB_PASS="$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)"
    echo
    b "Generiertes DB-Passwort: ${DB_PASS}"
  else
    echo
  fi

  # Early state (so Manager greift auch bei Abbruch)
  cat > "${STATE_FILE}" <<EOF
MODE='${MODE}'
API_VER='${API_VER}'
FE_VER='${FE_VER}'
API_URL='${API_URL}'
FE_URL='${FE_URL}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
EOF

  echo
  b "Starte Installation…"
  install_packages
  prepare_db "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
  create_system_user
  download_api "${API_VER}"
  write_api_config "${API_URL}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${FE_URL}" "${MODE}"
  write_systemd_service

  if [ "${MODE}" = "SEPARATE" ]; then
    download_frontend "${FE_VER}"
    write_frontend_config "${API_URL}/api/v1"
  fi

  echo
  b "🎉 Vikunja ist bereit!"
  echo "API lauscht intern:   http://127.0.0.1:3456"
  echo "Öffentliche API-URL:  ${API_URL}"
  if [ "${MODE}" = "SEPARATE" ]; then
    echo "Frontend-URL:         ${FE_URL}  (statisch aus ${FRONTEND_DIR})"
  else
    echo "Frontend-URL:         ${API_URL}  (aus dem FULL-Binary bereitgestellt)"
  fi
  echo
  echo "Reverse-Proxy Hinweise:"
  echo "  - Proxy ${API_URL}  →  http://127.0.0.1:3456"
  if [ "${MODE}" = "SEPARATE" ]; then
    echo "  - Frontend ${FE_URL} → statische Dateien aus ${FRONTEND_DIR}"
    echo "  - CORS ist für ${FE_URL} erlaubt; config.json zeigt auf ${API_URL}/api/v1"
  else
    echo "  - Eine Origin (kein CORS nötig); das Binary liefert Frontend & API."
  fi
  ok "Fertig."
}

# --- Manager menu --------------------------------------------------------------
manager_menu() {
  # STATE laden (falls vorhanden)
  [ -f "${STATE_FILE}" ] && . "${STATE_FILE}" || true

  # Falls keine State-Datei, aber Artefakte → provisorische Werte sammeln
  if [ ! -f "${STATE_FILE}" ] && is_installed; then
    warn "Bestehende Installation erkannt – generiere State-Datei."
    API_URL="$(awk -F': ' '/publicurl:/{print $2; exit}' "${API_CFG}" 2>/dev/null || true)"
    FE_URL="$(jq -r .api "${FRONTEND_CFG}" 2>/dev/null | sed 's|/api/v1$||' || echo "${API_URL}")"
    DB_NAME="$(awk -F': ' '/database:/ {f=1;next} f && /database:/{print $2; exit}' "${API_CFG}" 2>/dev/null || echo vikunja)"
    DB_USER="$(awk -F': ' '/user:/{print $2; exit}' "${API_CFG}" 2>/dev/null || echo vikunja)"
    MODE="$(awk -F': ' '/enabled:/{print $2; exit}' "${API_CFG}" 2>/dev/null | grep -qi true && echo SEPARATE || echo FULL)"
    API_VER="unknown"; FE_VER="unknown"; DB_PASS="(hidden)"

    cat > "${STATE_FILE}" <<EOF
MODE='${MODE}'
API_VER='${API_VER}'
FE_VER='${FE_VER}'
API_URL='${API_URL}'
FE_URL='${FE_URL}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
EOF
    . "${STATE_FILE}"
  fi

  echo
  b "================= VIKUNJA MANAGER ================="
  echo "Mode: ${MODE} | API: ${API_URL} | FE: ${FE_URL}"
  echo "Versions: API ${API_VER} / FE ${FE_VER}"
  echo
  echo "  1) Status anzeigen"
  echo "  2) Dienste starten"
  echo "  3) Dienste stoppen"
  echo "  4) Dienste neustarten"
  echo "  5) Neuinstallation (ALLES wird ersetzt)"
  echo "  6) Vollständig deinstallieren"
  echo "  7) Beenden"
  read -rp "Bitte wählen [1-7]: " choice

  case "$choice" in
    1) service_status ;;
    2) service_start ;;
    3) service_stop ;;
    4) service_restart ;;
    5)
      read -rp "Sicher? (ja/nein): " c
      if [ "$c" = "ja" ]; then
        cleanup_install "${DB_NAME:-vikunja}" "${DB_USER:-vikunja}"
        run_install
      else
        echo "Abbruch."
      fi
      ;;
    6)
      read -rp "WIRKLICH ALLES löschen? (ja/nein): " c
      if [ "$c" = "ja" ]; then
        cleanup_install "${DB_NAME:-vikunja}" "${DB_USER:-vikunja}"
        ok "Vikunja komplett entfernt."
      else
        echo "Abbruch."
      fi
      ;;
    7) echo "Tschüss."; exit 0 ;;
    *) err "Ungültige Auswahl."; exit 1 ;;
  esac
}

# --- Entry ---------------------------------------------------------------------
main() {
  require_root
  if [ -f "${STATE_FILE}" ] || is_installed; then
    manager_menu
  else
    b "Willkommen zum Vikunja-Installer."
    run_install
  fi
}
main
