
#!/bin/sh
# setup_vpn.sh — AmneziaWG: выборочная маршрутизация через nftables
# Policy routing: fwmark 0x1 -> table 100

set -e

# ==================== CONFIG ====================

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
HANDSHAKE_TIMEOUT="30"
KEEPALIVE="25"
NFT_FILE="/etc/nftables.d/99-awg-domains.nft"
NFT_INCLUDE_NAME="awg_domains"
AWG_ZONE_NAME="awg"

TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"

ORIGINAL_ROUTE_ALLOWED_IPS="$(uci -q get network.@amneziawg_awg[0].route_allowed_ips 2>/dev/null || true)"

# ==================== HELPERS ====================

log() {
    logger -t awg-setup "$*"
    echo "$*" >&2
}

die() {
    log "ОШИБКА: $*"
    rollback
    exit 1
}

rollback() {
    log "Откат изменений..."

    if [ -n "$ORIGINAL_ROUTE_ALLOWED_IPS" ]; then
        uci set network.@amneziawg_awg[0].route_allowed_ips="$ORIGINAL_ROUTE_ALLOWED_IPS" 2>/dev/null || true
    else
        uci -q delete network.@amneziawg_awg[0].route_allowed_ips 2>/dev/null || true
    fi

    uci -q delete network.awg_rule 2>/dev/null || true
    uci -q delete network.awg_route 2>/dev/null || true
    uci -q delete firewall.$NFT_INCLUDE_NAME 2>/dev/null || true

    uci commit network 2>/dev/null || true
    uci commit firewall 2>/dev/null || true

    rm -f "$NFT_FILE" 2>/dev/null || true

    ip route del default dev awg table "$RT_TABLE_ID" 2>/dev/null || true
    ip rule del fwmark "$FWMARK" lookup "$RT_TABLE_ID" 2>/dev/null || true

    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    /etc/init.d/network reload >/dev/null 2>&1 || true
}

ensure_wan_default() {
    if ip -4 route show table main default 2>/dev/null | grep -qv 'dev awg'; then
        return 0
    fi

    log "WAN default-маршрут отсутствует — ждём 10 секунд"
    sleep 10

    if ip -4 route show table main default 2>/dev/null | grep -qv 'dev awg'; then
        log "WAN default-маршрут восстановлен"
    else
        log "ВНИМАНИЕ: WAN default-маршрут не появился"
    fi
}

resolve_host() {
    host="$1"

    if command -v timeout >/dev/null 2>&1; then
        timeout "$DNS_TIMEOUT" nslookup "$host" 2>/dev/null |
            awk '/^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    else
        nslookup "$host" 2>/dev/null |
            awk '/^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    fi
}

fetch_list() {
    target="$1"

    for url in "$LIST_URL" $LIST_MIRRORS; do
        [ -z "$url" ] && continue

        log "Пробую: $url"

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

parse_list() {
    in="$1"
    out="$2"

    ENTRIES=$(sed 's/\r//g; s/#.*//g; s/^[[:space:]]*//; s/[[:space:]]*$//' "$in" | grep -v '^$')

    [ -n "$ENTRIES" ] || return 1

    > "$out"

    COUNT=0

    echo "$ENTRIES" | while IFS= read -r entry; do
        [ -z "$entry" ] && continue

        COUNT=$((COUNT+1))

        [ $((COUNT % 10)) -eq 0 ] && log "Обработано $COUNT записей..."

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

    sort -u "$out" -o "$out" 2>/dev/null ||
        { sort -u "$out" > "$out.tmp" && mv "$out.tmp" "$out"; }

    [ -s "$out" ]
}

gen_nft() {
    ips_file="$1"
    nft_file="$2"

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

ensure_awg_zone() {
    idx=""

    for i in $(uci show firewall | grep -oE '@zone\[[0-9]+\]=zone' | grep -oE '[0-9]+'); do
        if [ "$(uci -q get firewall.@zone[$i].name)" = "$AWG_ZONE_NAME" ]; then
            idx="$i"
            break
        fi
    done

    if [ -z "$idx" ]; then
        uci add firewall zone >/dev/null
        idx=$(( $(uci show firewall | grep -cE '@zone\[[0-9]+\]=zone') - 1 ))

        uci set firewall.@zone[$idx].name="$AWG_ZONE_NAME"
        uci set firewall.@zone[$idx].input='REJECT'
        uci set firewall.@zone[$idx].output='ACCEPT'
        uci set firewall.@zone[$idx].forward='ACCEPT'
        uci set firewall.@zone[$idx].masq='1'
        uci set firewall.@zone[$idx].masq6='1'
        uci set firewall.@zone[$idx].mtu_fix='1'

        log "Создана зона $AWG_ZONE_NAME"
    else
        log "Зона $AWG_ZONE_NAME уже существует (index $idx)"
    fi

    if ! uci -q get firewall.@zone[$idx].network 2>/dev/null | grep -qw 'awg'; then
        uci add_list firewall.@zone[$idx].network='awg'
    fi

    uci set firewall.@zone[$idx].masq='1'
    uci set firewall.@zone[$idx].mtu_fix='1'
    uci set firewall.@zone[$idx].forward='ACCEPT'

    echo "$idx"
}

ensure_forwarding() {
    indices=""

    for i in $(uci show firewall | grep -oE '@forwarding\[[0-9]+\]=forwarding' | grep -oE '[0-9]+'); do
        if [ "$(uci -q get firewall.@forwarding[$i].dest)" = "$AWG_ZONE_NAME" ]; then
            indices="$indices $i"
        fi
    done

    count=0
    [ -n "$indices" ] && count=$(echo "$indices" | wc -w)

    if [ "$count" -eq 0 ]; then
        uci add firewall forwarding >/dev/null
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest="$AWG_ZONE_NAME"

        log "Добавлен forwarding lan -> awg"

    elif [ "$count" -gt 1 ]; then
        first=1

        for i in $indices; do
            if [ "$first" = "1" ]; then
                first=0
                continue
            fi

            uci delete firewall.@forwarding[$i]
            log "Удалён дублирующий forwarding[$i]"
        done
    else
        log "Forwarding lan -> awg уже существует"
    fi
}

wait_handshake() {
    elapsed=0

    while [ "$elapsed" -lt "$HANDSHAKE_TIMEOUT" ]; do
        if awg show 2>/dev/null | grep -q 'latest handshake'; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))

        log "Ожидание handshake: ${elapsed}s"
    done

    return 1
}

# ==================== 0. DOWNLOAD ====================

log "0. Скачивание списка..."

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"

fetch_list "$TMP_RAW" || die "Не удалось скачать список"

# ==================== 1. CHECK ====================

log "1. Проверка окружения..."

[ -f /etc/iproute2/rt_tables ] || die "Нет rt_tables"
command -v nft >/dev/null 2>&1 || die "Нет nft"
command -v uci >/dev/null 2>&1 || die "Нет uci"
command -v awg >/dev/null 2>&1 || die "Нет awg"

uci -q get network.awg >/dev/null 2>&1 ||
    die "network.awg не настроен"

log "Базовые проверки пройдены"

# ==================== 2. HANDSHAKE ====================

log "2. Обеспечение handshake..."

if [ -z "$(uci -q get network.@amneziawg_awg[0].persistent_keepalive 2>/dev/null)" ]; then
    uci set network.@amneziawg_awg[0].persistent_keepalive="$KEEPALIVE"
fi

uci set network.@amneziawg_awg[0].route_allowed_ips='1'
uci commit network

ifup awg >/dev/null 2>&1 || true

if ! wait_handshake; then
    log "ВНИМАНИЕ: handshake не появился"
else
    log "Handshake появился"
fi

# ==================== 3. PARSE ====================

log "3. Парсинг списка..."

parse_list "$TMP_RAW" "$TMP_IPS" ||
    die "Не удалось получить IP"

IP_COUNT=$(wc -l < "$TMP_IPS")

log "Получено IP/CIDR: $IP_COUNT"

# ==================== 4. NFT ====================

log "4. Генерация nft-конфига..."

mkdir -p /etc/nftables.d

gen_nft "$TMP_IPS" "$TMP_NFT" ||
    die "Не удалось создать nft-конфиг"

cp "$TMP_NFT" "$NFT_FILE"

# ==================== 5. UCI ====================

log "5. Настройка UCI..."

grep -q "$RT_TABLE_ID $RT_TABLE_NAME" /etc/iproute2/rt_tables ||
    echo "$RT_TABLE_ID $RT_TABLE_NAME" >> /etc/iproute2/rt_tables

uci set network.awg.auto='1'

ZONE_IDX=$(ensure_awg_zone)

log "Зона awg: index $ZONE_IDX"

ensure_forwarding

uci -q delete network.awg_rule 2>/dev/null || true
uci -q delete network.awg_route 2>/dev/null || true

uci -q delete firewall.$NFT_INCLUDE_NAME 2>/dev/null || true

uci set firewall.$NFT_INCLUDE_NAME=include
uci set firewall.$NFT_INCLUDE_NAME.type='nftables'
uci set firewall.$NFT_INCLUDE_NAME.path="$NFT_FILE"
uci set firewall.$NFT_INCLUDE_NAME.position='table-append'

uci commit network
uci commit firewall

/etc/init.d/firewall restart >/dev/null 2>&1 ||
    log "ВНИМАНИЕ: ошибка перезапуска firewall"

/etc/init.d/network reload >/dev/null 2>&1 ||
    log "ВНИМАНИЕ: ошибка reload network"

# ==================== 6. POLICY ROUTING HELPER ====================

log "6. Установка helper..."

POLICY_HELPER="/usr/bin/ensure_awg_policy.sh"
HOTPLUG_HELPER="/etc/hotplug.d/iface/95-awg-policy"

cat > "$POLICY_HELPER" << 'POLICY_EOF'
#!/bin/sh

TABLE="100"
MARK="0x1"
IFACE="awg"

ip link show "$IFACE" >/dev/null 2>&1 || exit 1

ip -4 route replace default dev "$IFACE" table "$TABLE" 2>/dev/null || exit 1

if ! ip -4 rule show |
    grep -Eq "fwmark ${MARK}([ /]|$).*lookup (${TABLE}|awg_vpn)([[:space:]]|$)"
then
    ip -4 rule add priority 10000 fwmark "${MARK}/0xffffffff" lookup "$TABLE" 2>/dev/null || {
        ip -4 rule show |
            grep -Eq "fwmark ${MARK}([ /]|$).*lookup (${TABLE}|awg_vpn)([[:space:]]|$)" || exit 1
    }
fi

ip -4 route flush cache 2>/dev/null || true

exit 0
POLICY_EOF

chmod 755 "$POLICY_HELPER"

mkdir -p /etc/hotplug.d/iface

cat > "$HOTPLUG_HELPER" << 'HOTPLUG_EOF'
#!/bin/sh

[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "awg" ] || exit 0

(
    sleep 2
    /usr/bin/ensure_awg_policy.sh
) >/dev/null 2>&1 &

exit 0
HOTPLUG_EOF

chmod 755 "$HOTPLUG_HELPER"

log "Helper и hotplug установлены"

ifup awg >/dev/null 2>&1 || true
sleep 3

if /usr/bin/ensure_awg_policy.sh; then
    log "Маршрут и fwmark установлены"
else
    log "ВНИМАНИЕ: пока не удалось установить маршрут/fwmark"
fi

# ==================== 7. SELECTIVE ROUTING ====================

log "7. Отключение route_allowed_ips..."

uci set network.@amneziawg_awg[0].route_allowed_ips='0'
uci commit network

ifup wan >/dev/null 2>&1 || true

sleep 3

ensure_wan_default

ifup awg >/dev/null 2>&1 || true

if wait_handshake; then

    log "Handshake сохранился"

    if /usr/bin/ensure_awg_policy.sh; then
        log "Policy routing активен"
    else
        log "ОШИБКА: policy routing не установлен"
    fi

    log "Перезапуск dnsmasq..."

    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

    sleep 2

else

    log "ВНИМАНИЕ: handshake потерян"
    log "Возвращаем route_allowed_ips=1"

    uci set network.@amneziawg_awg[0].route_allowed_ips='1'
    uci commit network

    ifup wan >/dev/null 2>&1 || true

    sleep 3

    ensure_wan_default

    ifup awg >/dev/null 2>&1 || true

    if wait_handshake; then
        log "Полный туннель восстановлен"
    else
        log "ОШИБКА: handshake не восстановился"
    fi
fi

# ==================== 8. UPDATE SCRIPT ====================

log "8. Установка update-скрипта..."

cat > "$UPDATE_SCRIPT" << 'UPD_EOF'
#!/bin/sh

LIST_URL="__LIST_URL__"
LIST_MIRRORS="__MIRRORS__"
DNS_TIMEOUT="__DNS_TIMEOUT__"

TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"
FINAL_NFT="/etc/nftables.d/99-awg-domains.nft"

log() {
    logger -t awg-updater "$*"
}

resolve_host() {
    host="$1"

    if command -v timeout >/dev/null 2>&1; then
        timeout "$DNS_TIMEOUT" nslookup "$host" 2>/dev/null |
            awk '/^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    else
        nslookup "$host" 2>/dev/null |
            awk '/^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    fi
}

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"

ok=0

for url in "$LIST_URL" $LIST_MIRRORS; do
    [ -z "$url" ] && continue

    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --connect-timeout 15 --max-time 180 -o "$TMP_RAW" "$url" &&
            [ -s "$TMP_RAW" ] && { ok=1; break; }
    else
        wget -4 -q -T 180 -O "$TMP_RAW" "$url" &&
            [ -s "$TMP_RAW" ] && { ok=1; break; }
    fi

    rm -f "$TMP_RAW"
done

[ "$ok" = "1" ] || {
    log "Download failed"
    exit 1
}

ENTRIES=$(sed 's/\r//g; s/#.*//g; s/^[[:space:]]*//; s/[[:space:]]*$//' "$TMP_RAW" | grep -v '^$')

[ -n "$ENTRIES" ] || {
    log "Empty list"
    exit 1
}

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

sort -u "$TMP_IPS" -o "$TMP_IPS" 2>/dev/null ||
    { sort -u "$TMP_IPS" > "$TMP_IPS.tmp" && mv "$TMP_IPS.tmp" "$TMP_IPS"; }

SORTED_IPS=$(tr '\n' ',' < "$TMP_IPS" | sed 's/,$//')

[ -n "$SORTED_IPS" ] || {
    log "No IP addresses"
    exit 1
}

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

    if /etc/init.d/firewall restart >/dev/null 2>&1; then
        log "Updated: $(wc -l < "$TMP_IPS") IP"
    else
        log "ERROR: firewall restart failed"
        exit 1
    fi

else
    log "No changes"
fi

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"

exit 0
UPD_EOF

sed -i "s|__LIST_URL__|$LIST_URL|" "$UPDATE_SCRIPT"

MIRRORS_ONELINE=$(echo "$LIST_MIRRORS" | tr '\n' ' ')

sed -i "s|__MIRRORS__|$MIRRORS_ONELINE|" "$UPDATE_SCRIPT"
sed -i "s|__DNS_TIMEOUT__|$DNS_TIMEOUT|" "$UPDATE_SCRIPT"

chmod +x "$UPDATE_SCRIPT"

# ==================== 9. CRON ====================

log "9. Настройка cron..."

mkdir -p /etc/crontabs
touch /etc/crontabs/root

sed -i "\|$UPDATE_SCRIPT|d" /etc/crontabs/root

echo "0 4 * * * $UPDATE_SCRIPT" >> /etc/crontabs/root

sed -i '\|ensure_awg_policy.sh|d' /etc/crontabs/root

echo "@reboot sleep 35 && /usr/bin/ensure_awg_policy.sh >/dev/null 2>&1" >> /etc/crontabs/root

/etc/init.d/cron enable
/etc/init.d/cron restart

# ==================== DONE ====================

log "Готово. Список: $IP_COUNT IP"

log "Маршрут:"
ip -4 route show table "$RT_TABLE_ID" 2>/dev/null

log "Правило:"
ip -4 rule show 2>/dev/null

log "Проверка: sh /usr/bin/check_vpn.sh"
