#!/bin/bash
# ==============================================================================
# Vikunja Installer & Manager (interactive)
# Debian 12 - MariaDB - Reverse Proxy friendly
# v1.7  (Modes: BINARY | SAME_ORIGIN_STATIC | SEPARATE)
# ==============================================================================
set -euo pipefail

# --- Globals ------------------------------------------------------------------
STATE_FILE="${HOME}/.vikunja_install_state"

API_BIN="/usr/local/bin/vikunja"
API_USER="vikunja"
API_GROUP="vikunja"
API_DATA_DIR="/var/lib/vikunja"
API_ETC_DIR="/etc/vikunja"
API_CFG="${API_ETC_DIR}/config.yml"
API_SERVICE="/etc/systemd/system/vikunja.service"

# Frontend-Ziele
FRONTEND_DIR_SEPARATE="/var/www/vikunja"           # eigenständige FE-Domain
FRONTEND_CFG_SEPARATE="${FRONTEND_DIR_SEPARATE}/config.json"

FRONTEND_DIR_SAME="/var/www/vikunja-frontend"      # gleiche Domain (service.staticpath)
FRONTEND_CFG_SAME="${FRONTEND_DIR_SAME}/config.json"

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

# --- Detect existing install ---------------------------------------------------
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
  apt-get upgrade -y || true
  apt-get install -y curl wget tar unzip ca-certificates gnupg lsb-release jq mariadb-server
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
  info "Systembenutzer ${API_USER} anlegen..."
  if ! id -u "${API_USER}" >/dev/null 2>&1; then
    useradd --system --home "${API_DATA_DIR}" --shell /usr/sbin/nologin "${API_USER}" || \
    adduser --system --home "${API_DATA_DIR}" --shell /usr/sbin/nologin "${API_USER}"
  fi
  mkdir -p "${API_DATA_DIR}" "${API_ETC_DIR}"
  chown -R "${API_USER}:${API_GROUP}" "${API_DATA_DIR}" 2>/dev/null || chown -R "${API_USER}:${API_USER}" "${API_DATA_DIR}" || true
  ok "Systembenutzer & Verzeichnisse vorbereitet."
}

# --- Download API (FULL zip includes frontend assets) --------------------------
download_api() {
  local ver="$1" arch zipname url binpath expected
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "Unbekannte Architektur $(uname -m), nehme amd64."; arch="amd64" ;;
  esac

  zipname="vikunja-v${ver#v}-linux-${arch}-full.zip"
  url="https://dl.vikunja.io/vikunja/${ver#v}/${zipname}"

  info "Lade ${url} ..."
  cd /tmp
  wget -q --show-progress "${url}"

  info "Ermittle Binary-Pfad im ZIP..."
  binpath="$(unzip -Z1 "${zipname}" \
    | grep -E '^vikunja($|-)' \
    | grep -Ev '\.sha256$|\.ya?ml$|\.txt$|\.md$|^LICENSE$|/$' \
    | head -n1 || true)"

  if [ -z "${binpath}" ]; then
    expected="vikunja-v${ver#v}-linux-${arch}"
    if unzip -Z1 "${zipname}" | grep -qx "${expected}"; then
      binpath="${expected}"
    fi
  fi

  if [ -z "${binpath}" ]; then
    binpath="$(unzip -Z1 "${zipname}" \
      | grep -E '^vikunja' \
      | grep -Ev '\.sha256$|\.ya?ml$|\.txt$|\.md$|^LICENSE$|/$' \
      | head -n1 || true)"
  fi

  if [ -z "${binpath}" ]; then
    err "Konnte die Vikunja-Binary im ZIP nicht finden."
    unzip -Z1 "${zipname}" | sed 's/^/  - /'
    exit 1
  fi

  info "Gefundene Binary: ${binpath}"
  info "Extrahiere Binary nach ${API_BIN} ..."
  unzip -p "${zipname}" "${binpath}" > "${API_BIN}"
  chmod 0755 "${API_BIN}"
  rm -f "${zipname}"
  ok "vikunja installiert: ${API_BIN}"
}

# --- Write API config ----------------------------------------------------------
# mode: BINARY | SAME_ORIGIN_STATIC | SEPARATE
write_api_config() {
  local public_url="$1" dbname="$2" dbuser="$3" dbpass="$4" fe_origin="$5" mode="$6" staticdir_same="$7"
  info "Schreibe ${API_CFG}..."
  mkdir -p "$(dirname "${API_CFG}")"

  # Basis
  cat > "${API_CFG}" <<EOF
service:
  publicurl: "${public_url}"
  interface: "0.0.0.0:3456"
EOF

  # SAME_ORIGIN_STATIC: eigenes Frontend aus Ordner ausliefern
  if [ "${mode}" = "SAME_ORIGIN_STATIC" ]; then
    cat >> "${API_CFG}" <<EOF
  staticpath: "${staticdir_same}"
EOF
  fi

  cat >> "${API_CFG}" <<EOF

log:
  level: "info"

database:
  type: "mysql"
  host: "127.0.0.1:3306"
  user: "${dbuser}"
  password: "${dbpass}"
  database: "${dbname}"

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

# --- Frontend (Downloads) ------------------------------------------------------
download_frontend_to() {
  local ver="${1:-}"
  local target_dir="${2:-}"
  if [[ -z "$ver" || -z "$target_dir" ]]; then
    echo "download_frontend_to: missing arguments. Usage: download_frontend_to <version> <target_dir>" >&2
    return 1
  fi
  ver="${ver#v}"

  local fezip="vikunja-frontend-${ver}.zip"
  local url="https://dl.vikunja.io/frontend/${fezip}"
  info "Lade Frontend: ${url} ..."
  mkdir -p "${target_dir}"
  cd /tmp
  wget -q --show-progress "${url}"
  unzip -oq "${fezip}" -d "${target_dir}"
  rm -f "${fezip}"
  ok "Frontend nach ${target_dir} installiert."
}

write_frontend_config_same_origin() {
  local dir="$1"
  info "Schreibe SAME_ORIGIN config.json (API relativ) ..."
  mkdir -p "${dir}"
  cat > "${dir}/config.json" <<EOF
{ "api": "/api/v1" }
EOF
  ok "config.json geschrieben: ${dir}/config.json"
}

write_frontend_config_separate() {
  local dir="$1" api_url="$2"
  info "Schreibe SEPARATE config.json (API absolut) ..."
  mkdir -p "${dir}"
  cat > "${dir}/config.json" <<EOF
{ "api": "${api_url}/api/v1" }
EOF
  ok "config.json geschrieben: ${dir}/config.json"
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

  rm -rf "${API_BIN}" "${API_ETC_DIR}" "${API_DATA_DIR}" "${FRONTEND_DIR_SEPARATE}" "${FRONTEND_DIR_SAME}" || true
  id "${API_USER}" >/dev/null 2>&1 && userdel -r "${API_USER}" 2>/dev/null || true
  rm -f "${STATE_FILE}"
  ok "Bereinigung abgeschlossen."
}

# --- Install flow --------------------------------------------------------------
run_install() {
  echo
  b "Installationsmodus wählen:"
  echo "  1) BINARY              – API liefert eingebettetes Frontend (eine Domain)"
  echo "  2) SAME_ORIGIN_STATIC  – API & Frontend gleiche Domain, Frontend aus Ordner (service.staticpath)"
  echo "  3) SEPARATE            – API & Frontend auf verschiedenen Domains (CORS nötig)"
  read -rp "Auswahl [1/2/3] (Default 1): " MODE_IN
  [ -z "${MODE_IN}" ] && MODE_IN=1
  case "$MODE_IN" in
    1) MODE="BINARY" ;;
    2) MODE="SAME_ORIGIN_STATIC" ;;
    3) MODE="SEPARATE" ;;
    *) err "Ungültige Auswahl."; exit 1 ;;
  esac

  read -rp "Vikunja API-Version (Default: ${DEFAULT_API_VER}): " API_VER_IN
  API_VER=${API_VER_IN:-${DEFAULT_API_VER}}

  FE_VER="(from binary)"
  if [ "${MODE}" = "SAME_ORIGIN_STATIC" ] || [ "${MODE}" = "SEPARATE" ]; then
    read -rp "Vikunja Frontend-Version (Default: ${DEFAULT_FE_VER}): " FE_VER_IN
    FE_VER=${FE_VER_IN:-${DEFAULT_FE_VER}}
  fi

  read -rp "Öffentliche API-URL (z.B. https://todo.example.de): " API_URL
  [ -z "${API_URL}" ] && { err "API-URL darf nicht leer sein."; exit 1; }

  if [ "${MODE}" = "SEPARATE" ]; then
    read -rp "Frontend-URL (z.B. https://app.example.de): " FE_URL
    [ -z "${FE_URL}" ] && { err "Frontend-URL darf nicht leer sein."; exit 1; }
  else
    FE_URL="${API_URL}" # gleiche Origin
  fi

  read -rp "MariaDB-DB-Name [vikunja]: " DB_NAME_IN
  DB_NAME=${DB_NAME_IN:-vikunja}
  read -rp "MariaDB-User [vikunja]: " DB_USER_IN
  DB_USER=${DB_USER_IN:-vikunja}

  read -srp "MariaDB-Passwort (leer = generieren): " DB_PASS_IN
  echo
  if [ -z "${DB_PASS_IN}" ]; then
    DB_PASS="$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)"
    b "Generiertes DB-Passwort: ${DB_PASS}"
  else
    DB_PASS="${DB_PASS_IN}"
  fi

  # State speichern
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

  # Konfig schreiben (SAME_ORIGIN_STATIC setzt staticpath)
  if [ "${MODE}" = "SAME_ORIGIN_STATIC" ]; then
    mkdir -p "${FRONTEND_DIR_SAME}"
    write_api_config "${API_URL}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${FE_URL}" "${MODE}" "${FRONTEND_DIR_SAME}"
  else
    write_api_config "${API_URL}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}" "${FE_URL}" "${MODE}" ""
  fi

  write_systemd_service

  # Frontend deployment je nach Modus
  if [ "${MODE}" = "SAME_ORIGIN_STATIC" ]; then
    download_frontend_to "${FE_VER}" "${FRONTEND_DIR_SAME}"
    write_frontend_config_same_origin "${FRONTEND_DIR_SAME}"
  elif [ "${MODE}" = "SEPARATE" ]; then
    download_frontend_to "${FE_VER}" "${FRONTEND_DIR_SEPARATE}"
    write_frontend_config_separate "${FRONTEND_DIR_SEPARATE}" "${API_URL}"
  fi

  echo
  b "🎉 Vikunja ist bereit!"
  echo "API lauscht intern:   http://127.0.0.1:3456"
  echo "Öffentliche API-URL:  ${API_URL}"
  case "${MODE}" in
    BINARY)
      echo "Frontend-URL:         ${API_URL}  (aus der Binary eingebettet)"
      ;;
    SAME_ORIGIN_STATIC)
      echo "Frontend-URL:         ${API_URL}  (statisch aus ${FRONTEND_DIR_SAME} via service.staticpath)"
      ;;
    SEPARATE)
      echo "Frontend-URL:         ${FE_URL}   (statisch aus ${FRONTEND_DIR_SEPARATE})"
      ;;
  esac
  echo
  echo "Reverse-Proxy Hinweise:"
  echo "  - Proxy ${API_URL}  →  http://127.0.0.1:3456"
  if [ "${MODE}" = "SEPARATE" ]; then
    echo "  - Frontend ${FE_URL} → statische Dateien aus ${FRONTEND_DIR_SEPARATE}"
    echo "  - CORS ist für ${FE_URL} erlaubt; config.json zeigt auf ${API_URL}/api/v1"
  elif [ "${MODE}" = "SAME_ORIGIN_STATIC" ]; then
    echo "  - Frontend wird von Vikunja selbst aus ${FRONTEND_DIR_SAME} ausgeliefert (eine Origin, kein CORS)."
  else
    echo "  - Eine Origin (kein CORS nötig); das Binary liefert Frontend & API."
  fi
  ok "Fertig."
}

# --- Manager menu --------------------------------------------------------------
manager_menu() {
  [ -f "${STATE_FILE}" ] && . "${STATE_FILE}" || true

  if [ ! -f "${STATE_FILE}" ] && is_installed; then
    warn "Bestehende Installation erkannt – generiere State-Datei."
    API_URL="$(awk -F': ' '/publicurl:/{print $2; exit}' "${API_CFG}" 2>/dev/null || true)"
    FE_URL="$(jq -r .api "${FRONTEND_CFG_SEPARATE}" 2>/dev/null | sed 's|/api/v1$||' || echo "${API_URL}")"
    DB_NAME="$(awk -F': ' '/database:/ {f=1;next} f && /database:/{print $2; exit}' "${API_CFG}" 2>/dev/null || echo vikunja)"
    DB_USER="$(awk -F': ' '/user:/{print $2; exit}' "${API_CFG}" 2>/dev/null || echo vikunja)"
    MODE="$(awk '/^service:/,/^[^[:space:]]/{ if($0 ~ /staticpath:/){print "SAME_ORIGIN_STATIC"; exit}} END{if(!NR)print ""}' "${API_CFG}" 2>/dev/null)"
    if [ -z "${MODE}" ]; then
      if awk -F': ' '/enabled:/{print tolower($2); exit}' "${API_CFG}" 2>/dev/null | grep -q true; then
        MODE="SEPARATE"
      else
        MODE="BINARY"
      fi
    fi
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
  echo "Mode: ${MODE:-unknown} | API: ${API_URL:-unknown} | FE: ${FE_URL:-unknown}"
  echo "Versions: API ${API_VER:-unknown} / FE ${FE_VER:-unknown}"
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
