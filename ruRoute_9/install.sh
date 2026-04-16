#!/bin/bash

# ============================================================
#  ruRoute — умный split-routing для VPN серверов
#  https://github.com/ruRoute/ruRoute
#  Лицензия: MIT
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

RUROUTE_DIR="/usr/local/ruRoute"
LISTS_DIR="$RUROUTE_DIR/lists"
BACKUP_DIR="$RUROUTE_DIR/backups"
SERVICE_FILE="/etc/systemd/system/ruroute-watcher.service"
CRON_FILE="/etc/cron.d/ruroute"
REPO_RAW="https://raw.githubusercontent.com/hjty-0/ruRoute/main/ruRoute_9"
VERSION="1.0.0"

declare -A PANEL_CONFIG_PATHS=(
    ["3x-ui"]="/usr/local/x-ui/bin/config.json"
    ["marzban"]="/var/lib/marzban/xray_config.json"
    ["hiddify"]="/opt/hiddify-manager/hiddify-panel/config/xray_config.json"
    ["xray"]="/usr/local/etc/xray/config.json"
)

declare -A PANEL_SERVICE_NAMES=(
    ["3x-ui"]="x-ui"
    ["marzban"]="marzban"
    ["hiddify"]="hiddify-panel"
    ["xray"]="xray"
)

DETECTED_PANEL=""
CONFIG_PATH=""
OUTBOUND_TAG=""
IS_SINGBOX=false

# ── Утилиты ──────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[*]${NC} $1"; }
log_ok()      { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}\n"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запусти скрипт от root: sudo bash install.sh"
        exit 1
    fi
}

check_deps() {
    local missing=()
    for dep in curl jq inotifywait; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Устанавливаю зависимости: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq curl jq inotify-tools
        elif command -v yum &>/dev/null; then
            yum install -y -q curl jq inotify-tools
        else
            log_error "Установи вручную: ${missing[*]}"
            exit 1
        fi
    fi
}

# ── Определение панели ───────────────────────────────────────
detect_panel() {
    log_section "Определение панели"

    if [[ -d "/usr/local/x-ui" ]] || systemctl is-active --quiet x-ui 2>/dev/null; then
        DETECTED_PANEL="3x-ui"; CONFIG_PATH="${PANEL_CONFIG_PATHS[3x-ui]}"
        log_ok "Обнаружена панель: 3x-ui"

    elif [[ -d "/opt/marzban" ]] || systemctl is-active --quiet marzban 2>/dev/null; then
        DETECTED_PANEL="marzban"; CONFIG_PATH="${PANEL_CONFIG_PATHS[marzban]}"
        log_ok "Обнаружена панель: Marzban"

    elif [[ -d "/opt/hiddify-manager" ]] || systemctl is-active --quiet hiddify-panel 2>/dev/null; then
        DETECTED_PANEL="hiddify"; CONFIG_PATH="${PANEL_CONFIG_PATHS[hiddify]}"
        log_ok "Обнаружена панель: Hiddify"
        if [[ -f "/opt/hiddify-manager/sing-box/sing-box" ]]; then
            IS_SINGBOX=true; log_info "Режим: sing-box"
        else
            log_info "Режим: xray"
        fi

    elif command -v xray &>/dev/null || [[ -f "/usr/local/bin/xray" ]]; then
        DETECTED_PANEL="xray"; CONFIG_PATH="${PANEL_CONFIG_PATHS[xray]}"
        log_ok "Обнаружен: чистый xray"

    else
        log_warn "Панель не определена автоматически"
        echo ""
        echo "  1) 3x-ui"
        echo "  2) Marzban"
        echo "  3) Hiddify"
        echo "  4) Чистый xray"
        echo "  5) Указать путь вручную"
        read -rp "Выбор [1-5]: " choice
        case $choice in
            1) DETECTED_PANEL="3x-ui";   CONFIG_PATH="${PANEL_CONFIG_PATHS[3x-ui]}" ;;
            2) DETECTED_PANEL="marzban"; CONFIG_PATH="${PANEL_CONFIG_PATHS[marzban]}" ;;
            3) DETECTED_PANEL="hiddify"; CONFIG_PATH="${PANEL_CONFIG_PATHS[hiddify]}" ;;
            4) DETECTED_PANEL="xray";    CONFIG_PATH="${PANEL_CONFIG_PATHS[xray]}" ;;
            5) read -rp "Путь к config.json: " CONFIG_PATH; DETECTED_PANEL="xray" ;;
            *) log_error "Неверный выбор"; exit 1 ;;
        esac
    fi

    if [[ ! -f "$CONFIG_PATH" ]]; then
        log_warn "Конфиг не найден: $CONFIG_PATH"
        read -rp "Укажи правильный путь: " CONFIG_PATH
        [[ ! -f "$CONFIG_PATH" ]] && { log_error "Файл не найден"; exit 1; }
    fi

    log_ok "Конфиг: $CONFIG_PATH"
}

# ── Определение outbound тега ────────────────────────────────
detect_outbound_tag() {
    log_section "Определение outbound на зарубеж"

    local tags
    tags=$(jq -r '.outbounds[]?.tag // empty' "$CONFIG_PATH" 2>/dev/null || echo "")

    if [[ -z "$tags" ]]; then
        log_warn "Не удалось прочитать outbounds"
        read -rp "Введи тег outbound вручную (например proxy-nl): " OUTBOUND_TAG
        return
    fi

    echo "Найденные outbound теги:"
    local i=1
    local tag_array=()
    while IFS= read -r tag; do
        echo "  $i) $tag"
        tag_array+=("$tag")
        ((i++))
    done <<< "$tags"

    echo ""
    read -rp "Выбери номер тега для зарубежного трафика: " tag_choice

    if [[ "$tag_choice" =~ ^[0-9]+$ ]] && (( tag_choice >= 1 && tag_choice <= ${#tag_array[@]} )); then
        OUTBOUND_TAG="${tag_array[$((tag_choice-1))]}"
        log_ok "Выбран outbound: $OUTBOUND_TAG"
    else
        read -rp "Введи тег вручную: " OUTBOUND_TAG
    fi
}

# ── Загрузка баз ─────────────────────────────────────────────
download_lists() {
    log_section "Загрузка баз доменов"
    mkdir -p "$LISTS_DIR"

    # 1. Ручная база ruRoute
    log_info "Скачиваю ручную базу ruRoute..."
    if curl -fsSL --max-time 30 "$REPO_RAW/lists/domains-manual.txt"         -o "$LISTS_DIR/domains-manual.txt" 2>/dev/null; then
        local c; c=$(grep -v '^#' "$LISTS_DIR/domains-manual.txt" | grep -vc '^$')
        log_ok "Ручная база ruRoute: $c доменов"
    else
        log_warn "Репо недоступен, использую встроенную базу"
        create_builtin_list
    fi

    # 2. itdoginfo/allow-domains
    log_info "Скачиваю itdoginfo/allow-domains..."
    if curl -fsSL --max-time 60         "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst"         -o "$LISTS_DIR/domains-itdog.txt" 2>/dev/null; then
        local c; c=$(grep -vc '^$' "$LISTS_DIR/domains-itdog.txt")
        log_ok "itdoginfo: $c доменов"
    else
        log_warn "itdoginfo недоступен, пропускаю"
        touch "$LISTS_DIR/domains-itdog.txt"
    fi

    # 3. hxehex/russia-mobile-internet-whitelist
    log_info "Скачиваю hxehex/russia-mobile-internet-whitelist..."
    if curl -fsSL --max-time 60         "https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/whitelist.txt"         -o "$LISTS_DIR/domains-hxehex.txt" 2>/dev/null; then
        local c; c=$(grep -vc '^$' "$LISTS_DIR/domains-hxehex.txt")
        log_ok "hxehex: $c доменов"
    else
        log_warn "hxehex недоступен, пропускаю"
        touch "$LISTS_DIR/domains-hxehex.txt"
    fi

    # 4. antifilter.download — полная база доменов (1.3М)
    log_info "Скачиваю antifilter.download/list/domains.lst..."
    local blocked_ok=false

    if curl -fsSL --max-time 120         "https://antifilter.download/list/domains.lst"         -o "$LISTS_DIR/domains-antizapret.txt" 2>/dev/null &&         [[ $(wc -l < "$LISTS_DIR/domains-antizapret.txt") -gt 1000 ]]; then
        local c; c=$(wc -l < "$LISTS_DIR/domains-antizapret.txt")
        log_ok "antifilter domains: $c доменов"
        blocked_ok=true
    fi

    # Fallback — community edition
    if [[ "$blocked_ok" == false ]]; then
        log_info "Пробую community.antifilter.download..."
        if curl -fsSL --max-time 60             "https://community.antifilter.download/list/domains.txt"             -o "/tmp/af-community.txt" 2>/dev/null; then
            grep -oP "(?<=\*://\*\.)[^/]+" /tmp/af-community.txt |                 sort -u > "$LISTS_DIR/domains-antizapret.txt"
            rm -f /tmp/af-community.txt
            local c; c=$(wc -l < "$LISTS_DIR/domains-antizapret.txt")
            log_ok "community antifilter: $c доменов"
            blocked_ok=true
        fi
    fi

    if [[ "$blocked_ok" == false ]]; then
        log_warn "antifilter недоступен, пропускаю"
        touch "$LISTS_DIR/domains-antizapret.txt"
    fi

    # 5. IP диапазоны российских AS
    log_info "Скачиваю IP диапазоны российских AS..."
    if curl -fsSL --max-time 60 "https://antifilter.download/list/subnet.lst"         -o "$LISTS_DIR/cidr-ru.txt" 2>/dev/null; then
        local c; c=$(wc -l < "$LISTS_DIR/cidr-ru.txt")
        log_ok "IP диапазоны: $c записей"
    else
        log_warn "Не удалось скачать IP диапазоны"
        touch "$LISTS_DIR/cidr-ru.txt"
    fi

    # Итого
    local total
    total=$(
        { grep -v '^#' "$LISTS_DIR/domains-manual.txt"     2>/dev/null
          grep -v '^#' "$LISTS_DIR/domains-itdog.txt"      2>/dev/null
          grep -v '^#' "$LISTS_DIR/domains-hxehex.txt"     2>/dev/null
          grep -v '^#' "$LISTS_DIR/domains-antizapret.txt" 2>/dev/null
          grep -v '^#' "$LISTS_DIR/domains-coder.txt"      2>/dev/null
        } | grep -v '^$' | sed 's|^\*\.||' | sort -u | wc -l
    )
    log_ok "Итого уникальных доменов: $total"
}

create_builtin_list() {
    cat > "$LISTS_DIR/domains-manual.txt" << 'EOF'
# ruRoute — ручная база российских доменов
# Обновляется мейнтейнером. Запросы → GitHub Discussions

# Госсервисы
gosuslugi.ru
mos.ru
nalog.ru
pfr.gov.ru
fssp.gov.ru
fns.gov.ru

# Банки
sber.ru
sberbank.ru
sbbol.ru
tinkoff.ru
tbank.ru
vtb.ru
vtb24.ru
alfabank.ru
raiffeisen.ru
gazprombank.ru
rshb.ru
otkritie.ru
sovcombank.ru
rosbank.ru
mkb.ru
pochtabank.ru
bspb.ru
uralsib.ru
akbars.ru
homecredit.ru
psbank.ru

# Маркетплейсы
wildberries.ru
ozon.ru
avito.ru
dns-shop.ru
citilink.ru
mvideo.ru
eldorado.ru
sbermegamarket.ru
megamarket.ru
lamoda.ru
aliexpress.ru

# Яндекс
yandex.ru
ya.ru
yandex.net
yandexcloud.net
kinopoisk.ru

# Соцсети и почта
vk.com
vk.ru
ok.ru
odnoklassniki.ru
mail.ru
bk.ru
inbox.ru
list.ru
rambler.ru

# Медиа
rbc.ru
ria.ru
tass.ru
kommersant.ru
vedomosti.ru
lenta.ru
fontanka.ru
gazeta.ru
aif.ru
mk.ru
kp.ru

# Стриминг
ivi.ru
okko.tv
more.tv
start.ru
kion.ru
wink.ru
rutube.ru
smotrim.ru

# Доставка
delivery-club.ru
kuper.ru
samokat.ru
vprok.ru

# Работа
hh.ru
superjob.ru
rabota.ru

# Недвижимость и авто
domclick.ru
cian.ru
auto.ru
drom.ru

# Телеком
mts.ru
beeline.ru
megafon.ru
tele2.ru
rostelecom.ru

# Прочее
2gis.ru
rzd.ru
aeroflot.ru
pobeda.aero
s7.ru
utair.ru
EOF
    log_ok "Встроенная база создана"
}

# ── Применение routing rules ─────────────────────────────────
backup_config() {
    mkdir -p "$BACKUP_DIR"
    cp "$CONFIG_PATH" "$BACKUP_DIR/config.$(date +%Y%m%d_%H%M%S).json"
    log_ok "Бэкап сохранён"
}

build_domains_json() {
    {
        grep -v '^#' "$LISTS_DIR/domains-manual.txt"     2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-itdog.txt"      2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-hxehex.txt"     2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-antizapret.txt" 2>/dev/null
        grep -v '^#' "$LISTS_DIR/domains-coder.txt"      2>/dev/null
    } | grep -v '^[[:space:]]*$' | sed 's|^\*\.||' | sort -u | jq -R . | jq -s .
}

build_cidr_json() {
    grep -v '^#' "$LISTS_DIR/cidr-ru.txt" 2>/dev/null | \
    grep -v '^[[:space:]]*$' | sort -u | jq -R . | jq -s . || echo '[]'
}

apply_routing_xray() {
    log_info "Формирую routing rules для xray..."
    local f_domains; f_domains=$(mktemp)
    local f_cidr;    f_cidr=$(mktemp)
    local f_routing; f_routing=$(mktemp)
    local tmp;       tmp=$(mktemp)

    build_domains_json > "$f_domains"
    build_cidr_json    > "$f_cidr"

    jq -n \
        --slurpfile d "$f_domains" \
        --slurpfile c "$f_cidr" \
        --arg tag "$OUTBOUND_TAG" \
        '{
            domainStrategy: "IPIfNonMatch",
            rules: [
                {type:"field", domain:$d[0], outboundTag:"direct"},
                {type:"field", ip:(["geoip:ru"]+$c[0]), outboundTag:"direct"},
                {type:"field", network:"tcp,udp", outboundTag:$tag}
            ]
        }' > "$f_routing"

    jq --slurpfile routing "$f_routing" '.routing = $routing[0]' "$CONFIG_PATH" > "$tmp"

    if jq empty "$tmp" 2>/dev/null; then
        cp "$tmp" "$CONFIG_PATH"
        local dc; dc=$(jq 'length' "$f_domains")
        local cc; cc=$(jq 'length' "$f_cidr")
        rm -f "$tmp" "$f_domains" "$f_cidr" "$f_routing"
        log_ok "Rules применены: $dc доменов, $cc CIDR + geoip:ru → direct; остальное → $OUTBOUND_TAG"
    else
        rm -f "$tmp" "$f_domains" "$f_cidr" "$f_routing"
        log_error "Ошибка валидации JSON"; exit 1
    fi
}

apply_routing_singbox() {
    log_info "Формирую routing rules для sing-box..."
    local f_domains; f_domains=$(mktemp)
    local f_route;   f_route=$(mktemp)
    local tmp;       tmp=$(mktemp)

    build_domains_json > "$f_domains"

    jq -n \
        --slurpfile d "$f_domains" \
        --arg tag "$OUTBOUND_TAG" \
        '{
            rules: [
                {domain_suffix:$d[0], outbound:"direct"},
                {geoip:["ru"], outbound:"direct"},
                {outbound:$tag}
            ],
            final: $tag
        }' > "$f_route"

    jq --slurpfile route "$f_route" '.route = $route[0]' "$CONFIG_PATH" > "$tmp"

    if jq empty "$tmp" 2>/dev/null; then
        cp "$tmp" "$CONFIG_PATH"
        rm -f "$tmp" "$f_domains" "$f_route"
        log_ok "Rules применены (sing-box)"
    else
        rm -f "$tmp" "$f_domains" "$f_route"
        log_error "Ошибка валидации JSON"; exit 1
    fi
}

apply_routing() {
    log_section "Применение routing rules"
    backup_config
    $IS_SINGBOX && apply_routing_singbox || apply_routing_xray
}

# ── Сохранение конфига ruRoute ───────────────────────────────
save_config() {
    cat > "$RUROUTE_DIR/config.env" << EOF
RUROUTE_VERSION="$VERSION"
RUROUTE_CONFIG_PATH="$CONFIG_PATH"
RUROUTE_OUTBOUND_TAG="$OUTBOUND_TAG"
RUROUTE_PANEL="$DETECTED_PANEL"
RUROUTE_IS_SINGBOX="$IS_SINGBOX"
RUROUTE_LISTS_DIR="$LISTS_DIR"
RUROUTE_PANEL_SERVICE="${PANEL_SERVICE_NAMES[$DETECTED_PANEL]:-xray}"
RUROUTE_INSTALLED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    log_ok "Конфиг ruRoute: $RUROUTE_DIR/config.env"
}

# ── Патч SQLite 3x-ui — routing rules в БД панели ────────────
patch_3xui_db() {
    [[ "$DETECTED_PANEL" != "3x-ui" ]] && return 0

    log_section "Патч базы данных 3x-ui"

    # Ищем БД
    local db_path=""
    for p in "/usr/local/x-ui/db/x-ui.db" "/etc/x-ui/x-ui.db" "/root/x-ui.db"; do
        [[ -f "$p" ]] && db_path="$p" && break
    done

    if [[ -z "$db_path" ]]; then
        log_warn "БД 3x-ui не найдена, пропускаю патч БД"
        return 0
    fi

    if ! command -v sqlite3 &>/dev/null; then
        log_info "Устанавливаю sqlite3..."
        apt-get install -y -qq sqlite3 2>/dev/null || yum install -y -q sqlite3 2>/dev/null || true
    fi

    if ! command -v sqlite3 &>/dev/null; then
        log_warn "sqlite3 недоступен, пропускаю патч БД"
        return 0
    fi

    log_info "Патчу routing в БД: $db_path"

    # Бэкап БД
    cp "$db_path" "$BACKUP_DIR/x-ui.db.$(date +%Y%m%d_%H%M%S)"

    # Читаем текущий шаблон routing из БД
    local current_routing
    current_routing=$(sqlite3 "$db_path"         "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null)

    if [[ -z "$current_routing" ]]; then
        log_warn "Не удалось прочитать шаблон из БД"
        return 0
    fi

    # Патчим domainStrategy и добавляем geoip:ru + geosite:category-ru
    local patched
    patched=$(echo "$current_routing" | python3 -c "
import sys, json

data = json.load(sys.stdin)

# Меняем domainStrategy
if 'routing' not in data:
    data['routing'] = {}
data['routing']['domainStrategy'] = 'IPIfNonMatch'

# Добавляем наши rules перед последним правилом (proxy-nl)
rules = data['routing'].get('rules', [])

# Убираем старые ruRoute rules если есть
rules = [r for r in rules if r.get('_ruRoute') != True]

# Находим позицию последнего правила с proxy-nl
insert_pos = len(rules)
for i, r in enumerate(rules):
    if r.get('outboundTag') == 'proxy-nl' or r.get('inboundTag'):
        insert_pos = i
        break

# Вставляем наши rules
ru_rules = [
    {'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:category-ru'], '_ruRoute': True},
    {'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:ru'], '_ruRoute': True}
]
for i, r in enumerate(ru_rules):
    rules.insert(insert_pos + i, r)

data['routing']['rules'] = rules
print(json.dumps(data, ensure_ascii=False))
" 2>/dev/null)

    if [[ -z "$patched" ]]; then
        log_warn "Ошибка при патче шаблона, пропускаю"
        return 0
    fi

    # Сохраняем обратно в БД (экранируем одинарные кавычки)
    local escaped
    escaped=$(echo "$patched" | sed "s/'/''/g")
    sqlite3 "$db_path"         "UPDATE settings SET value='$escaped' WHERE key='xrayTemplateConfig';" 2>/dev/null

    log_ok "БД 3x-ui успешно пропатчена — routing rules сохранены навсегда"
}

# ── Скрипт применения rules (переиспользуется) ───────────────
write_apply_script() {
    cat > "$RUROUTE_DIR/apply-routing.sh" << 'APPLY'
#!/bin/bash
source /usr/local/ruRoute/config.env

build_domains_json() {
    {
        grep -v '^#' "$RUROUTE_LISTS_DIR/domains-manual.txt"     2>/dev/null
        grep -v '^#' "$RUROUTE_LISTS_DIR/domains-itdog.txt"      2>/dev/null
        grep -v '^#' "$RUROUTE_LISTS_DIR/domains-hxehex.txt"     2>/dev/null
        grep -v '^#' "$RUROUTE_LISTS_DIR/domains-antizapret.txt" 2>/dev/null
        grep -v '^#' "$RUROUTE_LISTS_DIR/domains-coder.txt"      2>/dev/null
    } | grep -v '^[[:space:]]*$' | sed 's|^\*\.||' | sort -u | jq -R . | jq -s .
}

build_cidr_json() {
    grep -v '^#' "$RUROUTE_LISTS_DIR/cidr-ru.txt" 2>/dev/null | \
    grep -v '^[[:space:]]*$' | sort -u | jq -R . | jq -s . || echo '[]'
}

f_d=$(mktemp); f_c=$(mktemp); f_r=$(mktemp); tmp=$(mktemp)
build_domains_json > "$f_d"
build_cidr_json    > "$f_c"

if [ "$RUROUTE_IS_SINGBOX" = "true" ]; then
    jq -n --slurpfile d "$f_d" --arg t "$RUROUTE_OUTBOUND_TAG" \
        '{rules:[{domain_suffix:$d[0],outbound:"direct"},{geoip:["ru"],outbound:"direct"},{outbound:$t}],final:$t}' > "$f_r"
    jq --slurpfile route "$f_r" '.route = $route[0]' "$RUROUTE_CONFIG_PATH" > "$tmp"
else
    jq -n --slurpfile d "$f_d" --slurpfile c "$f_c" --arg t "$RUROUTE_OUTBOUND_TAG" \
        '{domainStrategy:"IPIfNonMatch",rules:[{type:"field",domain:$d[0],outboundTag:"direct"},{type:"field",ip:(["geoip:ru"]+$c[0]),outboundTag:"direct"},{type:"field",network:"tcp,udp",outboundTag:$t}]}' > "$f_r"
    jq --slurpfile routing "$f_r" '.routing = $routing[0]' "$RUROUTE_CONFIG_PATH" > "$tmp"
fi

if jq empty "$tmp" 2>/dev/null; then
    cp "$tmp" "$RUROUTE_CONFIG_PATH"; rm -f "$tmp" "$f_d" "$f_c" "$f_r"
    echo "OK: routing rules применены"
else
    rm -f "$tmp" "$f_d" "$f_c" "$f_r"; echo "ERROR: невалидный JSON"; exit 1
fi
APPLY
    chmod +x "$RUROUTE_DIR/apply-routing.sh"
}

# ── inotify watcher ──────────────────────────────────────────
install_watcher() {
    log_section "Установка inotify watcher"

    write_apply_script

    # Скрипт который вызывается после изменения конфига панелью
    cat > "$RUROUTE_DIR/patch.sh" << PATCH
#!/bin/bash
source /usr/local/ruRoute/config.env
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] [ruRoute] \$1" >> /var/log/ruroute.log; }

log "Конфиг изменён панелью, накатываю routing rules..."
sleep 3

if ! jq empty "\$RUROUTE_CONFIG_PATH" 2>/dev/null; then
    log "ОШИБКА: конфиг не валидный JSON, пропускаю"
    exit 1
fi

bash /usr/local/ruRoute/apply-routing.sh && log "Rules применены" || log "ОШИБКА при применении rules"

systemctl reload "\$RUROUTE_PANEL_SERVICE" 2>/dev/null || systemctl restart "\$RUROUTE_PANEL_SERVICE"
log "Сервис \$RUROUTE_PANEL_SERVICE перезапущен"
PATCH
    chmod +x "$RUROUTE_DIR/patch.sh"

    # Systemd сервис
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=ruRoute inotify watcher
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do inotifywait -e close_write,moved_to "${CONFIG_PATH}" 2>/dev/null && bash ${RUROUTE_DIR}/patch.sh; done'
Restart=always
RestartSec=5
StandardOutput=append:/var/log/ruroute.log
StandardError=append:/var/log/ruroute.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ruroute-watcher --quiet
    systemctl restart ruroute-watcher
    log_ok "Watcher запущен — следит за $CONFIG_PATH"
}

# ── Cron ─────────────────────────────────────────────────────
install_cron() {
    log_section "Автообновление баз"
    cat > "$CRON_FILE" << EOF
# ruRoute — обновление баз каждый день в 3:00
0 3 * * * root bash $RUROUTE_DIR/update-lists.sh >> /var/log/ruroute.log 2>&1
EOF
    log_ok "Cron: обновление каждый день в 3:00"
}

# ── Перезапуск сервиса ───────────────────────────────────────
restart_service() {
    log_section "Перезапуск сервиса"
    local svc="${PANEL_SERVICE_NAMES[$DETECTED_PANEL]:-xray}"
    if systemctl is-active --quiet "$svc"; then
        systemctl restart "$svc"
        sleep 2
        if systemctl is-active --quiet "$svc"; then
            log_ok "Сервис $svc перезапущен"
        else
            log_error "Сервис $svc не запустился!"
            log_error "Логи: journalctl -u $svc --no-pager -n 30"
            exit 1
        fi
    else
        log_warn "Сервис $svc не запущен, пропускаю"
    fi
}

# ── Баннер ───────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗ ██╗   ██╗██████╗  ██████╗ ██╗   ██╗████████╗███████╗"
    echo "  ██╔══██╗██║   ██║██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝██╔════╝"
    echo "  ██████╔╝██║   ██║██████╔╝██║   ██║██║   ██║   ██║   █████╗  "
    echo "  ██╔══██╗██║   ██║██╔══██╗██║   ██║██║   ██║   ██║   ██╔══╝  "
    echo "  ██║  ██║╚██████╔╝██║  ██║╚██████╔╝╚██████╔╝   ██║   ███████╗"
    echo "  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}Умный split-routing для VPN серверов${NC}  v${VERSION}"
    echo -e "  Российские сервисы → прямо | Остальное → зарубеж"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║      ruRoute установлен успешно! ✓       ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Панель:${NC}      $DETECTED_PANEL"
    echo -e "  ${BOLD}Конфиг:${NC}      $CONFIG_PATH"
    echo -e "  ${BOLD}Outbound:${NC}    $OUTBOUND_TAG"
    echo -e "  ${BOLD}Watcher:${NC}     активен (inotify)"
    echo -e "  ${BOLD}Обновление:${NC}  каждый день в 3:00"
    echo ""
    echo -e "  ${BOLD}Полезные команды:${NC}"
    echo -e "  ${CYAN}systemctl status ruroute-watcher${NC}   — статус"
    echo -e "  ${CYAN}tail -f /var/log/ruroute.log${NC}       — логи"
    echo -e "  ${CYAN}bash $RUROUTE_DIR/update-lists.sh${NC}  — обновить базы"
    echo -e "  ${CYAN}bash $RUROUTE_DIR/uninstall.sh${NC}     — удалить"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    check_deps
    mkdir -p "$RUROUTE_DIR" "$LISTS_DIR" "$BACKUP_DIR"
    detect_panel
    detect_outbound_tag
    download_lists
    apply_routing
    save_config
    patch_3xui_db
    install_watcher
    install_cron
    restart_service
    cp "$0" "$RUROUTE_DIR/install.sh" 2>/dev/null || true
    print_summary
}

main "$@"
