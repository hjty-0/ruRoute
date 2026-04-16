#!/bin/bash

# ============================================================
#  ruRoute — сборка geosite.dat
#  Собирает все домены в один geosite.dat файл
#  xray читает его через geosite:ruroute
# ============================================================

set -e

RUROUTE_DIR="/usr/local/ruRoute"
LISTS_DIR="$RUROUTE_DIR/lists"
BUILD_DIR="$RUROUTE_DIR/build"
XRAY_DIR="/usr/local/x-ui/bin"
GO_VERSION="1.22.0"
GO_DIR="/usr/local/go"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 1. Устанавливаем Go ──────────────────────────────────────
install_go() {
    if command -v go &>/dev/null; then
        local ver; ver=$(go version | grep -oP '\d+\.\d+')
        ok "Go уже установлен: $(go version)"
        return 0
    fi

    log "Устанавливаю Go ${GO_VERSION}..."
    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)       err "Неизвестная архитектура: $(uname -m)" ;;
    esac

    curl -fsSL --max-time 120 \
        "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
        -o /tmp/go.tar.gz

    rm -rf "$GO_DIR"
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz

    export PATH="$GO_DIR/bin:$PATH"
    echo "export PATH=$GO_DIR/bin:\$PATH" >> /etc/profile.d/go.sh

    ok "Go установлен: $(go version)"
}

# ── 2. Клонируем v2fly/domain-list-community ────────────────
setup_builder() {
    log "Подготавливаю сборщик geosite..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Скачиваем утилиту dlc (domain-list-community compiler)
    if [[ ! -f "$BUILD_DIR/dlc" ]]; then
        log "Скачиваю компилятор domain-list-community..."
        
        # Клонируем репо с компилятором
        if [[ ! -d "$BUILD_DIR/domain-list-community" ]]; then
            git clone --depth 1 \
                "https://github.com/v2fly/domain-list-community.git" \
                "$BUILD_DIR/domain-list-community" 2>/dev/null || \
            { warn "git clone не удался, пробую без depth..."; \
              git clone "https://github.com/v2fly/domain-list-community.git" \
                "$BUILD_DIR/domain-list-community"; }
        fi

        cd "$BUILD_DIR/domain-list-community"
        export PATH="$GO_DIR/bin:$PATH"
        go build -o "$BUILD_DIR/dlc" . 2>/dev/null
        ok "Компилятор собран"
    else
        ok "Компилятор уже есть"
    fi
}

# ── 3. Готовим список доменов ────────────────────────────────
prepare_domains() {
    log "Готовлю список доменов..."
    mkdir -p "$BUILD_DIR/data"

    # Объединяем все источники
    {
        grep -v '^#' "$LISTS_DIR/domains-manual.txt"     2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-itdog.txt"      2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-hxehex.txt"     2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-antizapret.txt" 2>/dev/null
    } | grep -v '^[[:space:]]*$' | \
        sed 's|^\*\.||' | \
        grep -E '^[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' | \
        sort -u > "$BUILD_DIR/domains-all.txt"

    local total; total=$(wc -l < "$BUILD_DIR/domains-all.txt")
    ok "Итого уникальных доменов: $total"

    # Формат для domain-list-community: просто домены
    cp "$BUILD_DIR/domains-all.txt" "$BUILD_DIR/data/ruroute"

    ok "Файл данных готов: $BUILD_DIR/data/ruroute"
}

# ── 4. Собираем geosite.dat ──────────────────────────────────
build_geosite() {
    log "Собираю geosite.dat..."
    cd "$BUILD_DIR/domain-list-community"
    export PATH="$GO_DIR/bin:$PATH"

    # Запускаем компилятор с нашим data директорием
    "$BUILD_DIR/dlc" \
        --datapath="$BUILD_DIR/data" \
        --outputname="geosite.dat" \
        --outputdir="$BUILD_DIR" \
        --exportlists="ruroute" 2>/dev/null || \
    "$BUILD_DIR/dlc" \
        --datapath="$BUILD_DIR/data" \
        --outputdir="$BUILD_DIR" 2>/dev/null

    if [[ ! -f "$BUILD_DIR/geosite.dat" ]]; then
        err "geosite.dat не собрался"
    fi

    local size; size=$(du -h "$BUILD_DIR/geosite.dat" | cut -f1)
    ok "geosite.dat собран: $size"
}

# ── 5. Устанавливаем geosite.dat ─────────────────────────────
install_geosite() {
    log "Устанавливаю geosite.dat..."

    # Бэкап старого
    [[ -f "$XRAY_DIR/geosite.dat" ]] && \
        cp "$XRAY_DIR/geosite.dat" "$XRAY_DIR/geosite.dat.bak"

    cp "$BUILD_DIR/geosite.dat" "$XRAY_DIR/geosite.dat"
    ok "geosite.dat установлен: $XRAY_DIR/geosite.dat"
}

# ── 6. Обновляем конфиг xray ─────────────────────────────────
update_xray_config() {
    log "Обновляю конфиг xray..."

    local config="$XRAY_DIR/config.json"
    local tmp; tmp=$(mktemp)

    # DNS конфиг с российскими серверами
    local dns_config
    dns_config=$(jq -n '{
        servers: [
            {
                address: "77.88.8.8",
                domains: ["geosite:ruroute"],
                skipFallback: true
            },
            {
                address: "77.88.8.1",
                domains: ["geosite:ruroute"],
                skipFallback: true
            },
            "8.8.8.8"
        ],
        queryStrategy: "UseIPv4"
    }')

    # Routing с geosite:ruroute вместо 1.3М доменов
    local routing
    routing=$(jq -n \
        --arg tag "$(grep RUROUTE_OUTBOUND_TAG /usr/local/ruRoute/config.env | cut -d'"' -f2)" \
        '{
            domainStrategy: "IPIfNonMatch",
            rules: [
                {type:"field", domain:["geosite:ruroute"], outboundTag:"direct"},
                {type:"field", ip:["geoip:ru"], outboundTag:"direct"},
                {type:"field", network:"tcp,udp", outboundTag:$tag}
            ]
        }')

    jq --argjson routing "$routing" \
       --argjson dns "$dns_config" \
       '.routing = $routing | .dns = $dns' "$config" > "$tmp"

    if jq empty "$tmp" 2>/dev/null; then
        cp "$tmp" "$config"
        rm -f "$tmp"
        ok "Конфиг обновлён — теперь использует geosite:ruroute"
    else
        rm -f "$tmp"
        err "Ошибка валидации JSON"
    fi
}

# ── 7. Патчим БД 3x-ui ───────────────────────────────────────
patch_3xui_db() {
    local db_path=""
    for p in "/etc/x-ui/x-ui.db" "/usr/local/x-ui/db/x-ui.db" "/root/x-ui.db"; do
        [[ -f "$p" ]] && db_path="$p" && break
    done

    [[ -z "$db_path" ]] && { warn "БД не найдена, пропускаю"; return 0; }

    log "Патчу БД 3x-ui..."

    local outbound_tag
    outbound_tag=$(grep RUROUTE_OUTBOUND_TAG /usr/local/ruRoute/config.env | cut -d'"' -f2)

    local current
    current=$(sqlite3 "$db_path" \
        "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null)

    [[ -z "$current" ]] && { warn "Шаблон не найден в БД"; return 0; }

    local patched
    patched=$(echo "$current" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tag = '$outbound_tag'

data['routing'] = {
    'domainStrategy': 'IPIfNonMatch',
    'rules': [
        {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
        {'type': 'field', 'outboundTag': 'blocked', 'ip': ['geoip:private']},
        {'type': 'field', 'outboundTag': 'blocked', 'protocol': ['bittorrent']},
        {'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:ruroute']},
        {'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:ru']},
        {'type': 'field', 'network': 'tcp,udp', 'outboundTag': tag}
    ]
}

data['dns'] = {
    'servers': [
        {'address': '77.88.8.8', 'domains': ['geosite:ruroute'], 'skipFallback': True},
        {'address': '77.88.8.1', 'domains': ['geosite:ruroute'], 'skipFallback': True},
        '8.8.8.8'
    ],
    'queryStrategy': 'UseIPv4'
}

print(json.dumps(data, ensure_ascii=False))
")

    local escaped
    escaped=$(echo "$patched" | sed "s/'/''/g")
    sqlite3 "$db_path" \
        "UPDATE settings SET value='$escaped' WHERE key='xrayTemplateConfig';" 2>/dev/null

    ok "БД 3x-ui пропатчена — geosite:ruroute + DNS"
}

# ── Main ─────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${GREEN}══ ruRoute — сборка geosite.dat ══${NC}"
    echo ""

    [[ $EUID -ne 0 ]] && err "Нужен root"

    install_go
    setup_builder
    prepare_domains
    build_geosite
    install_geosite
    update_xray_config
    patch_3xui_db

    # Перезапускаем x-ui
    log "Перезапускаю x-ui..."
    systemctl restart x-ui
    sleep 3
    systemctl is-active --quiet x-ui && ok "x-ui запущен" || err "x-ui не запустился"

    echo ""
    echo -e "${GREEN}══ geosite.dat установлен успешно! ══${NC}"
    echo ""
    echo "  Размер: $(du -h $XRAY_DIR/geosite.dat | cut -f1)"
    echo "  Доменов: $(wc -l < $BUILD_DIR/domains-all.txt)"
    echo "  Конфиг: geosite:ruroute → direct"
    echo ""
    echo "  Обновить базы: bash $RUROUTE_DIR/build-geosite.sh"
    echo ""
}

main "$@"
