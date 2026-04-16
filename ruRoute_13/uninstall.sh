#!/bin/bash

#  ruRoute — удаление v2.0.0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${CYAN}[*]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Запусти от root: sudo bash uninstall.sh${NC}"; exit 1; }

echo -e "\n${BOLD}${RED}ruRoute — удаление${NC}\n"

read -rp "Восстановить оригинальный конфиг из бэкапа? [y/N]: " restore
read -rp "Удалить Go (/usr/local/go)? [y/N]: " rmgo
read -rp "Удалить логи /var/log/ruroute.log? [y/N]: " rmlogs

# Останавливаем watcher
log_info "Останавливаю watcher..."
systemctl stop ruroute-watcher 2>/dev/null || true
systemctl disable ruroute-watcher 2>/dev/null || true
rm -f /etc/systemd/system/ruroute-watcher.service
systemctl daemon-reload
log_ok "Watcher остановлен"

# Удаляем cron
rm -f /etc/cron.d/ruroute
log_ok "Cron удалён"

# Восстанавливаем конфиг
if [[ "$restore" =~ ^[Yy]$ ]]; then
    CONFIG_PATH=$(grep RUROUTE_CONFIG_PATH /usr/local/ruRoute/config.env 2>/dev/null | cut -d'"' -f2)
    BACKUP_DIR="/usr/local/ruRoute/backups"
    if [[ -d "$BACKUP_DIR" ]] && ls "$BACKUP_DIR"/*.json &>/dev/null; then
        latest=$(ls -t "$BACKUP_DIR"/*.json | head -1)
        cp "$latest" "$CONFIG_PATH"
        log_ok "Конфиг восстановлен из: $latest"
        PANEL_SVC=$(grep RUROUTE_PANEL_SERVICE /usr/local/ruRoute/config.env 2>/dev/null | cut -d'"' -f2)
        systemctl restart "${PANEL_SVC:-xray}" 2>/dev/null && log_ok "Сервис перезапущен" || true
    else
        log_warn "Бэкапы не найдены"
    fi
fi

# Удаляем geosite.dat
XRAY_DIRS=("/usr/local/x-ui/bin" "/var/lib/marzban" "/opt/hiddify-manager/xray")
for d in "${XRAY_DIRS[@]}"; do
    [[ -f "$d/geosite.dat" ]] && rm -f "$d/geosite.dat" && log_ok "geosite.dat удалён из $d"
    [[ -f "$d/geosite.dat.bak" ]] && mv "$d/geosite.dat.bak" "$d/geosite.dat" && log_ok "geosite.dat восстановлен из бэкапа"
done

# Удаляем директорию ruRoute
rm -rf /usr/local/ruRoute
log_ok "Директория /usr/local/ruRoute удалена"

# Удаляем Go если нужно
if [[ "$rmgo" =~ ^[Yy]$ ]]; then
    rm -rf /usr/local/go /etc/profile.d/go.sh
    log_ok "Go удалён"
fi

# Удаляем логи
if [[ "$rmlogs" =~ ^[Yy]$ ]]; then
    rm -f /var/log/ruroute.log
    log_ok "Логи удалены"
fi

echo ""
echo -e "${BOLD}${GREEN}ruRoute успешно удалён.${NC}"
echo ""
