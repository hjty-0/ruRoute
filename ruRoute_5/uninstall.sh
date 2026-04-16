#!/bin/bash

# ============================================================
#  ruRoute — удаление
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
log_info()  { echo -e "${CYAN}[*]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запусти от root: sudo bash uninstall.sh${NC}"
    exit 1
fi

echo -e "\n${BOLD}${RED}ruRoute — удаление${NC}\n"

read -rp "Восстановить оригинальный конфиг из бэкапа? [y/N]: " restore

# Останавливаем и удаляем watcher
log_info "Останавливаю watcher..."
systemctl stop ruroute-watcher 2>/dev/null || true
systemctl disable ruroute-watcher 2>/dev/null || true
rm -f /etc/systemd/system/ruroute-watcher.service
systemctl daemon-reload
log_ok "Watcher остановлен и удалён"

# Удаляем cron
rm -f /etc/cron.d/ruroute
log_ok "Cron удалён"

# Восстанавливаем конфиг если нужно
if [[ "$restore" =~ ^[Yy]$ ]]; then
    CONFIG_PATH=$(grep RUROUTE_CONFIG_PATH /usr/local/ruRoute/config.env 2>/dev/null | cut -d'"' -f2)
    BACKUP_DIR="/usr/local/ruRoute/backups"

    if [[ -d "$BACKUP_DIR" ]] && ls "$BACKUP_DIR"/*.json &>/dev/null; then
        latest=$(ls -t "$BACKUP_DIR"/*.json | head -1)
        cp "$latest" "$CONFIG_PATH"
        log_ok "Конфиг восстановлен из: $latest"

        # Перезапускаем сервис
        PANEL_SVC=$(grep RUROUTE_PANEL_SERVICE /usr/local/ruRoute/config.env 2>/dev/null | cut -d'"' -f2)
        systemctl restart "${PANEL_SVC:-xray}" 2>/dev/null && log_ok "Сервис перезапущен" || true
    else
        log_warn "Бэкапы не найдены"
    fi
fi

# Удаляем директорию ruRoute
rm -rf /usr/local/ruRoute
log_ok "Директория /usr/local/ruRoute удалена"

# Логи — спрашиваем
read -rp "Удалить логи /var/log/ruroute.log? [y/N]: " rmlogs
if [[ "$rmlogs" =~ ^[Yy]$ ]]; then
    rm -f /var/log/ruroute.log
    log_ok "Логи удалены"
fi

echo ""
echo -e "${BOLD}${GREEN}ruRoute успешно удалён.${NC}"
echo ""
