#!/bin/sh
# setup_vpn_fixed.sh — AmneziaWG policy routing + domain/IP list updater
# Порядок: проверка -> скачивание -> парсинг -> nft -> uci -> cron

set -e

# ==================== КОНФИГ ====================
LIST_URL="https://raw.githubusercontent.com/dorogoyw-ui/Disk-Fix-Script/main/list"
LIST_MIRRORS="
https://cdn.jsdelivr.net/gh/dorogoyw-ui/Disk-Fix-Script@main/list
https://ghproxy.net/https://raw.githubusercontent.com/dorogoyw-ui/Disk-Fix-Script/main/list
https://raw.gitmirror.com/dorogoyw-ui/Disk-Fix-Script/main/list
"
UPDATE_SCRIPT="/usr/bin/update_awg_domains.sh"
RT_TABLE_ID="100"
RT_TABLE_NAME="awg_vpn"
FWMARK="0x1"
DNS_TIMEOUT="5"

TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"
FINAL_NFT="/etc/nftables.d/99-awg-domains.nft"

# ==================== ХЕЛПЕРЫ ====================
log() { logger -t awg-setup "$*"; echo "$*"; }
die() { log "ОШИБКА: $*"; rollback; exit 1; }

rollback() {
    log "Откат изменений..."
    uci -q delete network.awg_rule  2>/dev/null || true
    uci -q delete network.awg_route 2>/dev/null || true
    uci commit network 2>/dev/null || true
    rm -f /etc/nftables.d/99-awg-domains.nft 2>/dev/null || true
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    /etc/init.d/network reload >/dev/null 2>&1 || true
}

# Резолв через системный dnsmasq (127.0.0.1:53) с таймаутом 5 сек.
# ВАЖНО: не передаём второй аргумент (внешний DNS) — в musl nslookup он игнорируется и может зависнуть.
resolve_host() {
    host="$1"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$DNS_TIMEOUT" nslookup "$host" 2>/dev/null \
            | awk '/^Address [0-9]+: / {print $3}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    else
        nslookup "$host" 2>/dev/null \
            | awk '/^Address [0-9]+: / {print $3}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    fi
}

# Скачивание с перебором зеркал. $1 — целевой файл.
fetch_list() {
    target="$1"
    for url in "$LIST_URL" $LIST_MIRRORS; do
        [ -z "$url" ] && continue
        log "  пробую: $url"
        if command -v curl >/dev/null 2>&1; then
            if curl -4 -fsSL --connect-timeout 15 --max-time 120 -o "$target" "$url"; then
                [ -s "$target" ] && return 0
            fi
        else
            if wget -4 -q -T 120 -O "$target" "$url"; then
                [ -s "$target" ] && return 0
            fi
        fi
        rm -f "$target"
    done
    return 1
}

# Парсинг списка: $1 — входной файл, $2 — выходной файл с IP/CIDR
parse_list() {
    in="$1"; out="$2"
    ENTRIES=$(sed 's/\r//g; s/#.*//g; s/^[[:space:]]*//; s/[[:space:]]*$//' "$in" | grep -v '^$')
    [ -n "$ENTRIES" ] || return 1
    > "$out"
    COUNT=0
    echo "$ENTRIES" | while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        COUNT=$((COUNT+1))
        [ $((COUNT % 10)) -eq 0 ] && log "  обработано $COUNT записей..."
        if echo "$entry" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then
            echo "$entry" >> "$out"
        else
            resolve_host "$entry" >> "$out" 2>/dev/null || true
            case "$entry" in
                www.*|*.*.*) ;;
                *) resolve_host "www.$entry" >> "$out" 2>/dev/null || true ;;
            esac
        fi
    done
    sort -u "$out" -o "$out" 2>/dev/null || { sort -u "$out" > "$out.tmp" && mv "$out.tmp" "$out"; }
    [ -s "$out" ]
}

# Генерация nft-конфига из списка IP. $1 — файл с IP, $2 — выходной nft
gen_nft() {
    ips_file="$1"; nft_file="$2"
    SORTED_IPS=$(tr '\n' ',' < "$ips_file" | sed 's/,$//')
    [ -n "$SORTED_IPS" ] || return 1
    cat > "$nft_file" << NFT_EOF
set vpn_domains {
    type ipv4_addr
    flags interval
    auto-merge
    elements = { $SORTED_IPS }
}

chain mangle_prerouting_awg {
    type filter hook prerouting priority mangle; policy accept;
    iifname "br-lan" ip daddr @vpn_domains meta mark set $FWMARK
}
NFT_EOF
}

# ==================== 1. ПРОВЕРКА ====================
log "1. Проверка окружения..."
[ -f /etc/iproute2/rt_tables ] || die "/etc/iproute2/rt_tables не найден"
command -v nft >/dev/null 2>&1 || die "nft не найден (нужен fw4/nftables)"
command -v uci >/dev/null 2>&1 || die "uci не найден"
if ! uci -q get network.awg >/dev/null 2>&1; then
    log "ВНИМАНИЕ: интерфейс 'awg' не найден в UCI — маршрут в таблицу $RT_TABLE_ID может не работать"
fi

# Быстрая проверка резолвера
if ! timeout "$DNS_TIMEOUT" nslookup google.com >/dev/null 2>&1; then
    log "ВНИМАНИЕ: dnsmasq не отвечает на google.com — пробую перезапустить..."
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    sleep 2
fi

# ==================== 2. СКАЧИВАНИЕ ====================
log "2. Скачивание списка..."
rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"
fetch_list "$TMP_RAW" || die "не удалось скачать список ни с одного зеркала (DNS/DPI?)"

# ==================== 3. ПАРСИНГ ====================
log "3. Парсинг списка..."
parse_list "$TMP_RAW" "$TMP_IPS" || die "не удалось получить ни одного IP (DNS-резолвинг не работает?)"
IP_COUNT=$(wc -l < "$TMP_IPS" 2>/dev/null || echo 0)
log "  получено IP/CIDR: $IP_COUNT"

# ==================== 4. NFT ====================
log "4. Генерация nft-конфига..."
gen_nft "$TMP_IPS" "$TMP_NFT" || die "не удалось сгенерировать nft-конфиг"

# ==================== 5. ПРИМЕНЕНИЕ ПРАВИЛ ====================
log "5. Применение сетевых правил..."
grep -q "$RT_TABLE_ID $RT_TABLE_NAME" /etc/iproute2/rt_tables \
    || echo "$RT_TABLE_ID $RT_TABLE_NAME" >> /etc/iproute2/rt_tables

uci -q delete network.awg_route
uci set network.awg_route=route
uci set network.awg_route.interface='awg'
uci set network.awg_route.target='0.0.0.0/0'
uci set network.awg_route.table="$RT_TABLE_ID"

uci -q delete network.awg_rule
uci set network.awg_rule=rule
uci set network.awg_rule.mark="$FWMARK"
uci set network.awg_rule.lookup="$RT_TABLE_ID"
uci commit network

cp "$TMP_NFT" "$FINAL_NFT"
/etc/init.d/firewall restart >/dev/null 2>&1 || log "ВНИМАНИЕ: firewall restart вернул ошибку"
/etc/init.d/network reload   >/dev/null 2>&1 || log "ВНИМАНИЕ: network reload вернул ошибку"

# ==================== 6. UPDATE-СКРИПТ ====================
log "6. Установка $UPDATE_SCRIPT..."
cat > "$UPDATE_SCRIPT" << 'UPD_EOF'
#!/bin/sh
# update_awg_domains.sh — обновление списка и nft-сета (автообновление)

LIST_URL="__LIST_URL__"
LIST_MIRRORS="__MIRRORS__"
DNS_TIMEOUT="__DNS_TIMEOUT__"
TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"
FINAL_NFT="/etc/nftables.d/99-awg-domains.nft"

log() { logger -t awg-updater "$*"; }

resolve_host() {
    host="$1"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$DNS_TIMEOUT" nslookup "$host" 2>/dev/null \
            | awk '/^Address [0-9]+: / {print $3}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    else
        nslookup "$host" 2>/dev/null \
            | awk '/^Address [0-9]+: / {print $3}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    fi
}

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"

ok=0
for url in "$LIST_URL" $LIST_MIRRORS; do
    [ -z "$url" ] && continue
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --connect-timeout 15 --max-time 180 -o "$TMP_RAW" "$url" && [ -s "$TMP_RAW" ] && { ok=1; break; }
    else
        wget -4 -q -T 180 -O "$TMP_RAW" "$url" && [ -s "$TMP_RAW" ] && { ok=1; break; }
    fi
    rm -f "$TMP_RAW"
done
[ "$ok" = "1" ] || { log "download failed (all mirrors)"; exit 1; }

ENTRIES=$(sed 's/\r//g; s/#.*//g; s/^[[:space:]]*//; s/[[:space:]]*$//' "$TMP_RAW" | grep -v '^$')
[ -n "$ENTRIES" ] || { log "empty after clean"; exit 1; }

> "$TMP_IPS"
echo "$ENTRIES" | while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if echo "$entry" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then
        echo "$entry" >> "$TMP_IPS"
    else
        resolve_host "$entry" >> "$TMP_IPS" 2>/dev/null || true
        case "$entry" in
            www.*|*.*.*) ;;
            *) resolve_host "www.$entry" >> "$TMP_IPS" 2>/dev/null || true ;;
        esac
    fi
done

sort -u "$TMP_IPS" -o "$TMP_IPS" 2>/dev/null || { sort -u "$TMP_IPS" > "$TMP_IPS.tmp" && mv "$TMP_IPS.tmp" "$TMP_IPS"; }
SORTED_IPS=$(tr '\n' ',' < "$TMP_IPS" | sed 's/,$//')
[ -n "$SORTED_IPS" ] || { log "no ips"; exit 1; }

cat > "$TMP_NFT" << NFT_EOF
set vpn_domains {
    type ipv4_addr
    flags interval
    auto-merge
    elements = { $SORTED_IPS }
}

chain mangle_prerouting_awg {
    type filter hook prerouting priority mangle; policy accept;
    iifname "br-lan" ip daddr @vpn_domains meta mark set 0x1
}
NFT_EOF

if ! cmp -s "$TMP_NFT" "$FINAL_NFT"; then
    cp "$TMP_NFT" "$FINAL_NFT"
    /etc/init.d/firewall restart >/dev/null 2>&1
    log "updated, firewall restarted ($(wc -l < "$TMP_IPS") IP)"
else
    log "no changes"
fi

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"
UPD_EOF

# Подстановка параметров в update-скрипт
sed -i "s|__LIST_URL__|$LIST_URL|" "$UPDATE_SCRIPT"
MIRRORS_ONELINE=$(echo "$LIST_MIRRORS" | tr '\n' ' ')
sed -i "s|__MIRRORS__|$MIRRORS_ONELINE|" "$UPDATE_SCRIPT"
sed -i "s|__DNS_TIMEOUT__|$DNS_TIMEOUT|" "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"

# ==================== 7. CRON ====================
log "7. Настройка cron (04:00 ежедневно)..."
mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i "\|$UPDATE_SCRIPT|d" /etc/crontabs/root
echo "0 4 * * * $UPDATE_SCRIPT" >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart

log "Готово. Список загружен ($IP_COUNT IP), правила применены."
log "Проверка: ip rule show | grep 0x1 ; ip route show table $RT_TABLE_ID ; nft list set inet fw4 vpn_domains | head"