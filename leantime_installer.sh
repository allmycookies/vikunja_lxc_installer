#!/bin/bash
# ==============================================================================
# Leantime Installer & Manager (Apache + PHP 8.2 + MariaDB) for Debian 12
# Reverse-Proxy friendly (Nginx Proxy Manager)
# v1.2
#  - Git Default-Branch Auto-Detect
#  - Release ZIP support (Composer skipped when no composer.json)
#  - config/.env alignment with official docs
# ==============================================================================

set -euo pipefail

STATE_FILE=".leantime_install_state"

WEB_ROOT="/var/www/leantime"
WEB_PUBLIC="${WEB_ROOT}/public"
APACHE_SITE="/etc/apache2/sites-available/leantime.conf"

DB_NAME_DEFAULT="leantime"
DB_USER_DEFAULT="leantime"

PHP_VER="8.2"
PHP_INI_TUNE="/etc/php/${PHP_VER}/apache2/conf.d/90-leantime.ini"

b()   { printf "\033[1m%s\033[0m\n" "$*"; }
ok()  { echo "✅ $*"; }
info(){ echo "→ $*"; }
warn(){ echo "⚠️  $*"; }
err() { echo "❌ $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Bitte als root ausführen."
    exit 1
  fi
}

is_installed() {
  if [ -f "${APACHE_SITE}" ] || [ -d "${WEB_ROOT}" ]; then
    return 0
  fi
  return 1
}

install_packages() {
  info "System-Update & Basis-Pakete…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y

  info "Installiere Apache, PHP ${PHP_VER} & Extensions, MariaDB, Git/Composer…"
  apt-get install -y \
    apache2 mariadb-server git unzip curl ca-certificates rsync \
    php${PHP_VER} php${PHP_VER}-mysql php${PHP_VER}-mbstring php${PHP_VER}-xml \
    php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-gd php${PHP_VER}-intl \
    php${PHP_VER}-bcmath php${PHP_VER}-cli php${PHP_VER}-opcache php${PHP_VER}-ldap \
    php${PHP_VER}-exif composer

  a2enmod rewrite headers env mime dir >/dev/null
  systemctl enable --now apache2
  systemctl enable --now mariadb
  ok "Pakete & Dienste bereit."
}

prepare_db() {
  local db="$1" user="$2" pass="$3"
  info "Richte MariaDB-Datenbank & Benutzer ein…"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
  ok "MariaDB konfiguriert."
}

fetch_leantime() {
  local method="$1" ref_or_url="$2"
  info "Hole Leantime (${method})…"
  rm -rf "${WEB_ROOT}"
  mkdir -p "${WEB_ROOT}"

  if [ "${method}" = "git" ]; then
    if [ -z "${ref_or_url}" ]; then
      info "Ermittle Default-Branch…"
      local default_ref
      default_ref="$(git ls-remote --symref https://github.com/Leantime/leantime.git HEAD 2>/dev/null | awk '/^ref:/ {print $2}' | awk -F/ '{print $3}')"
      if [ -z "${default_ref}" ]; then
        warn "Konnte Default-Branch nicht ermitteln – klone Repo-Default."
        git clone --depth 1 https://github.com/Leantime/leantime.git "${WEB_ROOT}"
      else
        info "Default-Branch: ${default_ref}"
        git clone --depth 1 --branch "${default_ref}" https://github.com/Leantime/leantime.git "${WEB_ROOT}"
      fi
    else
      # Ref validieren (Head/Tag)
      if git ls-remote --exit-code --heads https://github.com/Leantime/leantime.git "${ref_or_url}" >/dev/null 2>&1 \
      || git ls-remote --exit-code --tags  https://github.com/Leantime/leantime.git "refs/tags/${ref_or_url}" >/dev/null 2>&1; then
        git clone --depth 1 --branch "${ref_or_url}" https://github.com/Leantime/leantime.git "${WEB_ROOT}"
      else
        err "Ref '${ref_or_url}' nicht gefunden."
        echo "Beispiele:"
        echo "  Branches: $(git ls-remote --heads https://github.com/Leantime/leantime.git | awk '{print $2}' | awk -F/ '{print $3}' | paste -sd ', ' -)"
        echo "  Tags:     $(git ls-remote --tags  https://github.com/Leantime/leantime.git | awk '{print $2}' | awk -F/ '{print $3}' | grep -E '^v' | tail -n 10 | paste -sd ', ' -)"
        exit 1
      fi
    fi
  else
    cd /tmp
    wget -q --show-progress -O leantime.zip "${ref_or_url}"
    rm -rf /tmp/leantime_zip && mkdir -p /tmp/leantime_zip
    unzip -oq leantime.zip -d /tmp/leantime_zip
    local topdir
    topdir="$(find /tmp/leantime_zip -maxdepth 1 -mindepth 1 -type d | head -n1)"
    rsync -a "${topdir}/" "${WEB_ROOT}/"
    rm -rf /tmp/leantime.zip /tmp/leantime_zip
  fi

  ok "Leantime Code liegt in ${WEB_ROOT}"
}

composer_install() {
  info "Composer Install (prod)…"
  cd "${WEB_ROOT}"
  if [ -f "composer.json" ]; then
    if [ ! -d "vendor" ]; then
      COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
    fi
    ok "Composer done."
  else
    info "Kein composer.json gefunden – Release-ZIP erkannt, Composer wird übersprungen."
  fi
}

write_env() {
  local app_url="$1" dbname="$2" dbuser="$3" dbpass="$4"
  info "Erzeuge config/.env…"
  cd "${WEB_ROOT}"
  mkdir -p config
  if [ -f "config/sample.env" ] && [ ! -f "config/.env" ]; then
    cp config/sample.env config/.env
  fi

  # APP URL
  if grep -q "^APP_URL=" config/.env 2>/dev/null; then
    sed -i "s|^APP_URL=.*|APP_URL=${app_url}|g" config/.env
  else
    echo "APP_URL=${app_url}" >> config/.env
  fi

  # DB
  grep -q "^DB_CONNECTION=" config/.env 2>/dev/null || echo "DB_CONNECTION=mysql" >> config/.env
  sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|g" config/.env

  grep -q "^DB_HOST=" config/.env 2>/dev/null || echo "DB_HOST=127.0.0.1" >> config/.env
  sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|g" config/.env

  grep -q "^DB_PORT=" config/.env 2>/dev/null || echo "DB_PORT=3306" >> config/.env
  sed -i "s|^DB_PORT=.*|DB_PORT=3306|g" config/.env

  grep -q "^DB_DATABASE=" config/.env 2>/dev/null || echo "DB_DATABASE=${dbname}" >> config/.env
  sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${dbname}|g" config/.env

  grep -q "^DB_USERNAME=" config/.env 2>/dev/null || echo "DB_USERNAME=${dbuser}" >> config/.env
  sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${dbuser}|g" config/.env

  grep -q "^DB_PASSWORD=" config/.env 2>/dev/null || echo "DB_PASSWORD=${dbpass}" >> config/.env
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${dbpass}|g" config/.env

  ok "config/.env geschrieben."
}

write_apache_vhost() {
  local server_name="$1"
  info "Schreibe Apache vHost…"
  cat > "${APACHE_SITE}" <<EOF
<VirtualHost *:80>
    ServerName ${server_name}
    DocumentRoot ${WEB_PUBLIC}

    <Directory ${WEB_PUBLIC}>
        AllowOverride All
        Require all granted
        Options FollowSymLinks
    </Directory>

    # Security/Headers (Basis)
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set X-XSS-Protection "1; mode=block"

    ErrorLog \${APACHE_LOG_DIR}/leantime_error.log
    CustomLog \${APACHE_LOG_DIR}/leantime_access.log combined
</VirtualHost>
EOF

  a2dissite 000-default.conf >/dev/null 2>&1 || true
  a2ensite leantime.conf >/dev/null
  systemctl reload apache2
  ok "vHost aktiv."
}

tune_php() {
  info "PHP-Tuning…"
  cat > "${PHP_INI_TUNE}" <<EOF
; Leantime tuning
memory_limit = 512M
post_max_size = 64M
upload_max_filesize = 64M
max_execution_time = 120
; OPcache
opcache.enable=1
opcache.enable_cli=1
opcache.validate_timestamps=0
opcache.max_accelerated_files=20000
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
EOF
  systemctl reload apache2
  ok "PHP konfiguriert."
}

fix_permissions() {
  info "Dateirechte setzen…"
  chown -R www-data:www-data "${WEB_ROOT}"
  find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
  find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

  mkdir -p "${WEB_ROOT}/storage" "${WEB_PUBLIC}/userfiles" "${WEB_ROOT}/config"
  chown -R www-data:www-data "${WEB_ROOT}/storage" "${WEB_PUBLIC}/userfiles" "${WEB_ROOT}/config"
  chmod -R 775 "${WEB_ROOT}/storage" "${WEB_PUBLIC}/userfiles" "${WEB_ROOT}/config"
  ok "Berechtigungen passen."
}

cleanup_install() {
  warn "Bereinige Installation…"
  systemctl stop apache2 || true
  rm -f "${APACHE_SITE}" && a2ensite 000-default.conf >/dev/null 2>&1 || true
  systemctl reload apache2 || true

  local db="$1" user="$2"
  mysql -e "DROP DATABASE IF EXISTS \`${db}\`;" || true
  mysql -e "DROP USER IF EXISTS '${user}'@'localhost';" || true
  mysql -e "FLUSH PRIVILEGES;" || true

  rm -rf "${WEB_ROOT}" "${PHP_INI_TUNE}"
  systemctl reload apache2 || true
  rm -f "${STATE_FILE}"
  ok "Alles entfernt."
}

service_status()  { systemctl --no-pager status apache2 mariadb || true; }
service_start()   { systemctl start apache2 mariadb; ok "Dienste gestartet."; }
service_stop()    { systemctl stop apache2 mariadb; ok "Dienste gestoppt."; }
service_restart() { systemctl restart apache2 mariadb; ok "Dienste neu gestartet."; }

run_install() {
  echo
  b "Quellcode-Bezug wählen:"
  echo "  1) Git – Branch/Tag angeben (leer = Default-Branch)"
  echo "  2) ZIP-URL – Release-ZIP (Leantime-vX.Y.Z.zip)"
  read -rp "Auswahl [1/2] (Default 1): " SRC_MODE
  [ -z "${SRC_MODE}" ] && SRC_MODE=1

  local GIT_REF ZIP_URL
  if [ "${SRC_MODE}" = "1" ]; then
    read -rp "Git Ref (leer = Default-Branch): " GIT_REF
    GIT_REF="${GIT_REF:-}"
  else
    read -rp "ZIP-URL (z. B. https://github.com/Leantime/leantime/releases/download/v3.5.12/Leantime-v3.5.12.zip): " ZIP_URL
    [ -z "${ZIP_URL}" ] && { err "ZIP-URL darf nicht leer sein."; exit 1; }
  fi

  read -rp "Öffentliche URL (z. B. https://leantime.example.de): " APP_URL
  [ -z "${APP_URL}" ] && { err "URL darf nicht leer sein."; exit 1; }

  read -rp "vHost ServerName (z. B. leantime.example.de) – für Logs/Referenz: " SERVER_NAME
  [ -z "${SERVER_NAME}" ] && SERVER_NAME="$(echo "${APP_URL}" | sed 's#https\?://##; s#/##g')"

  read -rp "DB-Name [${DB_NAME_DEFAULT}]: " DB_NAME
  DB_NAME=${DB_NAME:-${DB_NAME_DEFAULT}}
  read -rp "DB-User [${DB_USER_DEFAULT}]: " DB_USER
  DB_USER=${DB_USER:-${DB_USER_DEFAULT}}

  read -srp "DB-Passwort (leer = generieren): " DB_PASS
  if [ -z "${DB_PASS}" ]; then
    DB_PASS="$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)"
    echo
    b "Generiertes DB-Passwort: ${DB_PASS}"
  else
    echo
  fi

  # Frühes Statefile
  cat > "${STATE_FILE}" <<EOF
APP_URL='${APP_URL}'
SERVER_NAME='${SERVER_NAME}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
SRC_MODE='${SRC_MODE}'
GIT_REF='${GIT_REF:-}'
ZIP_URL='${ZIP_URL:-}'
EOF

  install_packages
  prepare_db "${DB_NAME}" "${DB_USER}" "${DB_PASS}"

  if [ "${SRC_MODE}" = "1" ]; then
    fetch_leantime "git" "${GIT_REF}"
  else
    fetch_leantime "zip" "${ZIP_URL}"
  fi

  composer_install
  write_env "${APP_URL}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}"
  tune_php
  write_apache_vhost "${SERVER_NAME}"
  fix_permissions

  echo
  b "🎉 Leantime ist bereit!"
  echo "  URL (über Nginx Proxy Manager): ${APP_URL}"
  echo "  Interner Host:Port:              <LXC-IP>:80"
  echo
  echo "NPM-Proxy-Host: Domain ${SERVER_NAME} → http://<LXC-IP>:80"
  echo "  SSL im NPM aktivieren (Let's Encrypt), Force SSL, Websockets Support an."
  echo
  echo "Jetzt im Browser auf ${APP_URL}/install gehen und die DB/Benutzer-Einrichtung abschließen."
  ok "Fertig."
}

manager_menu() {
  [ -f "${STATE_FILE}" ] && . "${STATE_FILE}" || true

  echo
  b "================= LEANTIME MANAGER ================="
  echo "URL: ${APP_URL:-<unbekannt>}  |  vHost: ${SERVER_NAME:-<unbekannt>}"
  echo "DB: ${DB_NAME:-leantime} / ${DB_USER:-leantime}"
  echo
  echo "  1) Status anzeigen"
  echo "  2) Dienste starten"
  echo "  3) Dienste stoppen"
  echo "  4) Dienste neustarten"
  echo "  5) Neuinstallation (ersetzen)"
  echo "  6) Vollständig deinstallieren"
  echo "  7) Beenden"
  read -rp "Bitte wählen [1-7]: " c
  case "$c" in
    1) systemctl --no-pager status apache2 mariadb || true ;;
    2) systemctl start apache2 mariadb; ok "Dienste gestartet." ;;
    3) systemctl stop apache2 mariadb; ok "Dienste gestoppt." ;;
    4) systemctl restart apache2 mariadb; ok "Dienste neu gestartet." ;;
    5)
      read -rp "Sicher? (ja/nein): " x
      if [ "$x" = "ja" ]; then
        cleanup_install "${DB_NAME:-${DB_NAME_DEFAULT}}" "${DB_USER:-${DB_USER_DEFAULT}}"
        run_install
      else
        echo "Abbruch."
      fi
      ;;
    6)
      read -rp "WIRKLICH ALLES löschen? (ja/nein): " x
      if [ "$x" = "ja" ]; then
        cleanup_install "${DB_NAME:-${DB_NAME_DEFAULT}}" "${DB_USER:-${DB_USER_DEFAULT}}"
      else
        echo "Abbruch."
      fi
      ;;
    7) exit 0 ;;
    *) err "Ungültige Auswahl."; exit 1 ;;
  esac
}

main() {
  require_root
  if [ -f "${STATE_FILE}" ] || is_installed; then
    manager_menu
  else
    b "Willkommen zum Leantime-Installer."
    run_install
  fi
}
main
