#!/bin/bash

# ============================================================
#  ruRoute — обновление баз доменов
# ============================================================

source /usr/local/ruRoute/config.env 2>/dev/null || {
    echo "ruRoute не установлен. Запусти install.sh"
    exit 1
}

LISTS_DIR="$RUROUTE_LISTS_DIR"
REPO_RAW="https://raw.githubusercontent.com/ruRoute/ruRoute/main"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ruRoute] $1" | tee -a /var/log/ruroute.log; }

log "Начинаю обновление баз..."

# Ручная база из репо
log "Обновляю ручную базу..."
if curl -fsSL --max-time 30 "$REPO_RAW/lists/domains-manual.txt" \
    -o "$LISTS_DIR/domains-manual.txt.tmp" 2>/dev/null; then
    mv "$LISTS_DIR/domains-manual.txt.tmp" "$LISTS_DIR/domains-manual.txt"
    count=$(grep -v '^#' "$LISTS_DIR/domains-manual.txt" | grep -vc '^$' || true)
    log "Ручная база обновлена: $count доменов"
else
    log "WARN: не удалось обновить ручную базу"
    rm -f "$LISTS_DIR/domains-manual.txt.tmp"
fi

# Автобаза antifilter
log "Обновляю автобазу antifilter..."
if curl -fsSL --max-time 60 "https://antifilter.download/list/domains.lst" \
    -o "$LISTS_DIR/domains-auto.txt.tmp" 2>/dev/null; then
    mv "$LISTS_DIR/domains-auto.txt.tmp" "$LISTS_DIR/domains-auto.txt"
    count=$(wc -l < "$LISTS_DIR/domains-auto.txt")
    log "Автобаза обновлена: $count доменов"
else
    log "WARN: antifilter недоступен, используем старую базу"
    rm -f "$LISTS_DIR/domains-auto.txt.tmp"
fi

# CIDR диапазоны
log "Обновляю IP диапазоны..."
if curl -fsSL --max-time 60 "https://antifilter.download/list/subnet.lst" \
    -o "$LISTS_DIR/cidr-ru.txt.tmp" 2>/dev/null; then
    mv "$LISTS_DIR/cidr-ru.txt.tmp" "$LISTS_DIR/cidr-ru.txt"
    count=$(wc -l < "$LISTS_DIR/cidr-ru.txt")
    log "IP диапазоны обновлены: $count записей"
else
    log "WARN: не удалось обновить IP диапазоны"
    rm -f "$LISTS_DIR/cidr-ru.txt.tmp"
fi

# Применяем обновлённые bases
log "Применяю обновлённые routing rules..."
if bash /usr/local/ruRoute/apply-routing.sh; then
    log "Routing rules применены успешно"
else
    log "ОШИБКА при применении rules"
    exit 1
fi

# Перезапускаем сервис
log "Перезапускаю сервис $RUROUTE_PANEL_SERVICE..."
systemctl reload "$RUROUTE_PANEL_SERVICE" 2>/dev/null || \
systemctl restart "$RUROUTE_PANEL_SERVICE"
log "Готово. Обновление завершено."
