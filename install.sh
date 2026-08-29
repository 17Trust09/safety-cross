#!/usr/bin/env bash
#
# Safety Cross – Ein-Run-Setup für Raspberry Pi (32-bit Raspberry Pi OS Desktop)
#
#   sudo bash install.sh
#
# Richtet ein: Python-venv + Flask-App, SQLite-DB (admin/admin),
# Hardware-Lizenz (Pi-Seriennummer + HMAC), Kiosk (Chromium fullscreen),
# Maus-Auto-Hide (unclutter) und die Uhr:
#   - DS3231-RTC, WENN vorhanden (echte Hardware-Uhr, offline korrekt)
#   - sonst fake-hwclock (Zeit übersteht Reboot/Stromausfall bestmöglich)
#
# Idempotent: kann gefahrlos mehrfach laufen.
#
set -Eeuo pipefail

APP_DIR=/opt/safety-cross
APP_PORT=8002
USER="${SUDO_USER:-pi}"
CONFIG=""
if [ -f /boot/firmware/config.txt ]; then CONFIG=/boot/firmware/config.txt; else CONFIG=/boot/config.txt; fi
CHROME="$(command -v chromium || command -v chromium-browser || echo /usr/bin/chromium)"

log()  { echo -e "\033[1;34m[SC]\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  ⚠\033[0m $*"; }
fail() { echo -e "\033[1;31m  ✗ $*\033[0m"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Bitte mit sudo ausführen: sudo bash install.sh"

append_line() { # datei zeile
    grep -qxF "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}

# ---------------------------------------------------------------- Pakete
log "System aktualisieren + Pakete installieren (braucht Internet)"
apt-get update -y
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip \
    chromium chromium-browser unclutter i2c-tools 2>/dev/null \
    || apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip chromium-browser unclutter i2c-tools
ok "Pakete installiert"

# ---------------------------------------------------------------- Uhr (RTC / fake-hwclock)
log "Uhr konfigurieren (RTC, wenn vorhanden, sonst fake-hwclock)"
# I2C aktivieren + DS3231-Overlay (harmlos ohne RTC)
append_line "$CONFIG" "dtparam=i2c_arm=on"
append_line "$CONFIG" "dtoverlay=i2c-rtc,ds3231"
# HDMI-Fallback auf Full-HD (wie LHTPi): auch ohne EDID sicher 1080p
append_line "$CONFIG" "hdmi_force_hotplug=1"
append_line "$CONFIG" "hdmi_group=2"
append_line "$CONFIG" "hdmi_mode=82"

modprobe i2c-dev 2>/dev/null || true
if i2cdetect -y 1 2>/dev/null | grep -qiE "68"; then
    ok "DS3231-RTC erkannt -> nutze Hardware-Uhr, deaktiviere fake-hwclock"
    systemctl disable fake-hwclock 2>/dev/null || true
    systemctl stop fake-hwclock 2>/dev/null || true
    # Systemzeit einmal in die RTC schreiben (falls frisch gesteckt):
    hwclock -w 2>/dev/null || true
else
    warn "Keine DS3231-RTC erkannt -> nutze fake-hwclock (Zeit übersteht Reboot)"
    systemctl enable fake-hwclock 2>/dev/null || true
fi
timedatectl set-timezone Europe/Berlin 2>/dev/null || true
ok "Uhr konfiguriert"

# ---------------------------------------------------------------- Desktop-Autologin (für X/Kiosk)
log "Desktop-Autologin aktivieren (X für den Kiosk)"
raspi-config nonint do_boot_behaviour B4 2>/dev/null || true
ok "Autologin gesetzt"

# ---------------------------------------------------------------- App installieren
log "App nach $APP_DIR installieren"
mkdir -p "$APP_DIR"
for f in app.py db.py auth.py license.py requirements.txt; do
    cp "$(dirname "$0")/$f" "$APP_DIR/"
done
cp -r "$(dirname "$0")/templates" "$APP_DIR/"
cp -r "$(dirname "$0")/static" "$APP_DIR/"

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip -q
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"
ok "venv + Abhängigkeiten"

# DB initialisieren (admin/admin)
"$APP_DIR/venv/bin/python" -c "import db, auth; db.init_db(); auth.init_admin_password('admin'); print('DB ok')"
ok "SQLite-DB initialisiert (Login admin/admin)"

# ---------------------------------------------------------------- Lizenz
log "Hardware-Lizenz generieren (Pi-Seriennummer + HMAC)"
SECRET_FILE="$APP_DIR/.secret"
# Secret-Quelle (Priorität): 1) SAFETY_SECRET env, 2) /boot/safety-secret.txt, 3) zufällig
if [ -n "${SAFETY_SECRET:-}" ]; then
    printf '%s' "$SAFETY_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    ok "Secret aus SAFETY_SECRET übernommen"
elif [ -f /boot/safety-secret.txt ]; then
    cp /boot/safety-secret.txt "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    ok "Secret aus /boot/safety-secret.txt übernommen"
elif [ -f /boot/firmware/safety-secret.txt ]; then
    cp /boot/firmware/safety-secret.txt "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    ok "Secret aus /boot/firmware/safety-secret.txt übernommen"
elif [ -f "$SECRET_FILE" ]; then
    ok "Vorhandenes Secret wird weiterverwendet"
else
    head -c 32 /dev/urandom | base64 > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    warn "Zufälliges Secret erzeugt (Basis-Schutz: verhindert SD-Karten-Kopie)."
    warn "Für echten Schutz: SAFETY_SECRET/Datei nutzen und das Secret NUR bei dir aufbewahren."
fi
# Key über license.py erzeugen (eine Quelle der Wahrheit)
if "$APP_DIR/venv/bin/python" "$APP_DIR/license.py" --make-key >/dev/null 2>&1; then
    ok "Lizenz-Key geschrieben (gebunden an die Seriennummer dieses Pi)"
else
    warn "Lizenz-Key konnte nicht erzeugt werden (kein Pi erkannt?)."
fi

# ---------------------------------------------------------------- Kiosk-Skript
log "Kiosk-Startskript schreiben"
cat > "$APP_DIR/start_kiosk.sh" <<'EOF'
#!/bin/bash
APP_URL="http://127.0.0.1:8002"
LOG="/opt/safety-cross/kiosk.log"
echo "$(date) - Kiosk startet" >> "$LOG"

# Warte, bis die Web-App erreichbar ist (max. 60 s)
for i in $(seq 1 30); do
    if curl -s -o /dev/null --connect-timeout 2 "$APP_URL" 2>/dev/null; then
        echo "$(date) - App erreichbar" >> "$LOG"
        break
    fi
    sleep 2
done

# Feste Auflösung: Full-HD 1920x1080 (wie LHTPi/Terminboard)
xrandr --output HDMI-1 --primary --mode 1920x1080 --pos 0x0 >/dev/null 2>&1 || true

# Bildschirmschoner/Abschaltung aus
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true

# Maus-Auto-Hide (nach 2 s Inaktivität, zeigt sich bei Bewegung)
unclutter -idle 2 -root >/dev/null 2>&1 &

exec chromium-browser \
    --kiosk \
    --window-position=0,0 \
    --window-size=1920,1080 \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --no-first-run \
    --check-for-update-interval=31536000 \
    --disable-translate \
    --disable-features=TranslateUI \
    --autoplay-policy=no-user-gesture-required \
    --app="$APP_URL" >> "$LOG" 2>&1
EOF
chmod +x "$APP_DIR/start_kiosk.sh"
# Chromium-Binary im Skript robust machen (chromium-browser vs. chromium)
sed -i "s#exec chromium-browser#exec ${CHROME}#" "$APP_DIR/start_kiosk.sh"
ok "Kiosk-Skript geschrieben"

# ---------------------------------------------------------------- systemd-Services
log "systemd-Services anlegen"

cat > /etc/systemd/system/safety-cross.service <<EOF
[Unit]
Description=Safety Cross Web-App
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python app.py
Restart=always
RestartSec=5
StartLimitIntervalSec=120
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/safety-cross-kiosk.service <<EOF
[Unit]
Description=Safety Cross Kiosk
After=graphical.target safety-cross.service
Requires=safety-cross.service

[Service]
Type=simple
User=$USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$USER/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=$APP_DIR/start_kiosk.sh
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=120
StartLimitBurst=3

[Install]
WantedBy=graphical.target
EOF

chown -R "$USER":"$USER" "$APP_DIR"
systemctl daemon-reload
systemctl enable safety-cross.service
systemctl enable safety-cross-kiosk.service
systemctl restart safety-cross.service
ok "Services aktiviert + App gestartet"

# ---------------------------------------------------------------- Fertig
echo
log "Fertig!"
echo "  Web-App:  http://127.0.0.1:$APP_PORT"
echo "  Admin:    http://127.0.0.1:$APP_PORT/admin  (Login admin/admin)"
echo "  Lizenz:   $LICENSE_FILE (an diesen Pi gebunden)"
echo "  Uhr:      DS3231-RTC (falls vorhanden), sonst fake-hwclock"
echo "  Hinweis:  Ein Reboot ist nötig, damit RTC/I2C + Kiosk voll greifen:"
echo "            sudo reboot"
