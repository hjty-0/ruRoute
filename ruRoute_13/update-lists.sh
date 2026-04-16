#!/bin/bash

#  ruRoute — обновление баз доменов v2.0.0
#    - ruRoute ручная база
#    - itdoginfo/allow-domains
#    - hxehex/russia-mobile-internet-whitelist
#    - antifilter.download/list/domains.lst
#    - antifilter.download/list/subnet.lst (CIDR)

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

# 1. Ручная база ruRoute
log "Обновляю ручную базу ruRoute..."
if curl -fsSL --max-time 30 "$REPO_RAW/lists/domains-manual.txt" \
    -o "$TMP_DIR/domains-manual.txt" 2>/dev/null; then
    mv "$TMP_DIR/domains-manual.txt" "$LISTS_DIR/domains-manual.txt"
    count=$(grep -v '^#' "$LISTS_DIR/domains-manual.txt" | grep -vc '^$' || true)
    ok "Ручная база: $count доменов"
else
    warn "Не удалось обновить ручную базу, оставляю старую"
fi

# 2. itdoginfo/allow-domains
log "Обновляю itdoginfo/allow-domains..."
if curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst" \
    -o "$TMP_DIR/itdog.txt" 2>/dev/null; then
    mv "$TMP_DIR/itdog.txt" "$LISTS_DIR/domains-itdog.txt"
    count=$(wc -l < "$LISTS_DIR/domains-itdog.txt")
    ok "itdoginfo: $count доменов"
else
    warn "itdoginfo недоступен, оставляю старую базу"
fi

# 3. hxehex/russia-mobile-internet-whitelist
log "Обновляю hxehex/whitelist..."
if curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/whitelist.txt" \
    -o "$TMP_DIR/hxehex.txt" 2>/dev/null; then
    mv "$TMP_DIR/hxehex.txt" "$LISTS_DIR/domains-hxehex.txt"
    count=$(wc -l < "$LISTS_DIR/domains-hxehex.txt")
    ok "hxehex: $count доменов"
else
    warn "hxehex недоступен, оставляю старую базу"
fi

# 4. antifilter.download — полная база
log "Обновляю antifilter.download/list/domains.lst..."
if curl -fsSL --max-time 120 \
    "https://antifilter.download/list/domains.lst" \
    -o "$TMP_DIR/antizapret.txt" 2>/dev/null && \
    [[ $(wc -l < "$TMP_DIR/antizapret.txt") -gt 1000 ]]; then
    mv "$TMP_DIR/antizapret.txt" "$LISTS_DIR/domains-antizapret.txt"
    count=$(wc -l < "$LISTS_DIR/domains-antizapret.txt")
    ok "antifilter: $count доменов"
else
    warn "antifilter недоступен, оставляю старую базу"
fi

# 5. CIDR диапазоны
log "Обновляю IP диапазоны..."
if curl -fsSL --max-time 60 \
    "https://antifilter.download/list/subnet.lst" \
    -o "$TMP_DIR/cidr.txt" 2>/dev/null; then
    mv "$TMP_DIR/cidr.txt" "$LISTS_DIR/cidr-ru.txt"
    count=$(wc -l < "$LISTS_DIR/cidr-ru.txt")
    ok "IP диапазоны: $count записей"
else
    warn "Не удалось обновить IP диапазоны"
fi

# Итого
total=$(
    { grep -v '^#' "$LISTS_DIR/domains-manual.txt"     2>/dev/null
      grep -v '^#' "$LISTS_DIR/domains-itdog.txt"      2>/dev/null
      grep -v '^#' "$LISTS_DIR/domains-hxehex.txt"     2>/dev/null
      grep -v '^#' "$LISTS_DIR/domains-antizapret.txt" 2>/dev/null
    } | grep -v '^$' | sed 's|^\*\.||' | sort -u | wc -l
)
log "Итого уникальных доменов: $total"

# Пересобираем geosite.dat если есть сборщик
if [[ -f "/usr/local/ruRoute/build-geosite.sh" ]]; then
    log "Пересобираю geosite.dat..."
    if bash /usr/local/ruRoute/build-geosite.sh; then
        ok "geosite.dat пересобран, перезапускаю x-ui..."
        systemctl restart "$RUROUTE_PANEL_SERVICE"
    else
        warn "Сборка geosite.dat не удалась, применяю обычные rules..."
        bash /usr/local/ruRoute/apply-routing.sh
        kill -USR1 $(pgrep xray) 2>/dev/null || true
    fi
else
    log "Применяю routing rules..."
    bash /usr/local/ruRoute/apply-routing.sh
    kill -USR1 $(pgrep xray) 2>/dev/null || true
fi

ok "Обновление завершено"
log "════════════════════════════════════════"
