#!/bin/bash

# ============================================================
#  ruRoute — обновление баз доменов
#  Источники:
#    - itdoginfo/allow-domains (inside-raw.lst) — основной
#    - hxehex/russia-mobile-internet-whitelist
#    - AntiZapret
#    - ruRoute ручная база (domains-manual.txt из репо)
#    - antifilter.download (CIDR диапазоны)
# ============================================================

source /usr/local/ruRoute/config.env 2>/dev/null || {
    echo "ruRoute не установлен. Запусти install.sh"
    exit 1
}

LISTS_DIR="$RUROUTE_LISTS_DIR"
REPO_RAW="https://raw.githubusercontent.com/hjty-0/ruRoute/main"
TMP_DIR=$(mktemp -d)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ruRoute] $1" | tee -a /var/log/ruroute.log; }
ok()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ruRoute] ✓ $1" | tee -a /var/log/ruroute.log; }
warn(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ruRoute] ! $1" | tee -a /var/log/ruroute.log; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log "════════════════════════════════════════"
log "Начинаю обновление баз..."

# ── 1. Ручная база из репо ruRoute ───────────────────────────
log "Скачиваю ручную базу ruRoute..."
if curl -fsSL --max-time 30 \
    "$REPO_RAW/lists/domains-manual.txt" \
    -o "$TMP_DIR/domains-manual.txt" 2>/dev/null; then
    mv "$TMP_DIR/domains-manual.txt" "$LISTS_DIR/domains-manual.txt"
    count=$(grep -v '^#' "$LISTS_DIR/domains-manual.txt" | grep -vc '^$' || true)
    ok "Ручная база: $count доменов"
else
    warn "Не удалось обновить ручную базу ruRoute, оставляю старую"
fi

# ── 2. itdoginfo/allow-domains — основной community список ──
log "Скачиваю itdoginfo/allow-domains (inside-raw.lst)..."
if curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst" \
    -o "$TMP_DIR/itdog.txt" 2>/dev/null; then
    # Убираем комментарии и пустые строки
    grep -v '^#' "$TMP_DIR/itdog.txt" | grep -v '^$' > "$LISTS_DIR/domains-itdog.txt"
    count=$(wc -l < "$LISTS_DIR/domains-itdog.txt")
    ok "itdoginfo: $count доменов"
else
    warn "itdoginfo недоступен, оставляю старую базу"
    touch "$LISTS_DIR/domains-itdog.txt"
fi

# ── 3. hxehex/russia-mobile-internet-whitelist ───────────────
log "Скачиваю hxehex/russia-mobile-internet-whitelist..."
if curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/whitelist.txt" \
    -o "$TMP_DIR/hxehex.txt" 2>/dev/null; then
    grep -v '^#' "$TMP_DIR/hxehex.txt" | grep -v '^$' > "$LISTS_DIR/domains-hxehex.txt"
    count=$(wc -l < "$LISTS_DIR/domains-hxehex.txt")
    ok "hxehex: $count доменов"
else
    warn "hxehex недоступен, оставляю старую базу"
    touch "$LISTS_DIR/domains-hxehex.txt"
fi

# ── 4. coder-stump/russian-ori-list ─────────────────────────
log "Скачиваю coder-stump/russian-ori-list..."
if curl -fsSL --max-time 60     "https://raw.githubusercontent.com/coder-stump/russian-ori-list/main/russia.lst"     -o "$TMP_DIR/coder.txt" 2>/dev/null; then
    grep -v "^#" "$TMP_DIR/coder.txt" | grep -v "^$" > "$LISTS_DIR/domains-coder.txt"
    count=$(wc -l < "$LISTS_DIR/domains-coder.txt")
    ok "coder-stump: $count доменов"
else
    warn "coder-stump недоступен, оставляю старую базу"
    touch "$LISTS_DIR/domains-coder.txt"
fi

# ── 5. AntiZapret ────────────────────────────────────────────
log "Скачиваю AntiZapret..."
if curl -fsSL --max-time 60 \
    "https://antizapret.prostovpn.org/domains-export.txt" \
    -o "$TMP_DIR/antizapret.txt" 2>/dev/null; then
    grep -v '^#' "$TMP_DIR/antizapret.txt" | grep -v '^$' > "$LISTS_DIR/domains-antizapret.txt"
    count=$(wc -l < "$LISTS_DIR/domains-antizapret.txt")
    ok "AntiZapret: $count доменов"
else
    warn "AntiZapret недоступен, оставляю старую базу"
    touch "$LISTS_DIR/domains-antizapret.txt"
fi

# ── 6. antifilter.download — CIDR диапазоны ─────────────────
log "Скачиваю IP диапазоны (antifilter)..."
if curl -fsSL --max-time 60 \
    "https://antifilter.download/list/subnet.lst" \
    -o "$TMP_DIR/cidr.txt" 2>/dev/null; then
    mv "$TMP_DIR/cidr.txt" "$LISTS_DIR/cidr-ru.txt"
    count=$(wc -l < "$LISTS_DIR/cidr-ru.txt")
    ok "IP диапазоны: $count записей"
else
    warn "antifilter недоступен, оставляю старые диапазоны"
fi

# ── Статистика ───────────────────────────────────────────────
total=$(
    {
        grep -v '^#' "$LISTS_DIR/domains-manual.txt"     2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-itdog.txt"      2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-hxehex.txt"     2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-antizapret.txt" 2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-coder.txt"      2>/dev/null
    } | grep -v '^$' | sed 's|^[*][.]||' | sort -u | wc -l
)
log "Итого уникальных доменов (все источники): $total"

# ── Применяем обновлённые rules ──────────────────────────────
log "Применяю routing rules..."
if bash /usr/local/ruRoute/apply-routing.sh; then
    ok "Routing rules применены"
else
    warn "ОШИБКА при применении rules"
    exit 1
fi

# ── Перезапускаем сервис ─────────────────────────────────────
log "Перезапускаю $RUROUTE_PANEL_SERVICE..."
systemctl reload "$RUROUTE_PANEL_SERVICE" 2>/dev/null || \
systemctl restart "$RUROUTE_PANEL_SERVICE"
ok "Сервис перезапущен"
log "Обновление завершено."
log "════════════════════════════════════════"
