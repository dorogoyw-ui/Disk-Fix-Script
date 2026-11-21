#!/bin/sh
# setup_vpn.sh — AmneziaWG: зона, forwarding, fwmark->table 100, nft-set, cron
# Список скачивается ДО любых изменений сети (пока WAN-маршрут точно есть).
# PersistentKeepalive=25 удерживает NAT-привязку и handshake без route_allowed_ips.

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
HANDSHAKE_TIMEOUT="30"
KEEPALIVE="25"
NFT_FILE="/etc/nftables.d/99-awg-domains.nft"
NFT_INCLUDE_NAME="awg_domains"
AWG_ZONE_NAME="awg"

TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"

# ==================== ХЕЛПЕРЫ ====================
log() { logger -t awg-setup "$*"; echo "$*" >&2; }
die() { log "ОШИБКА: $*"; rollback; exit 1; }

rollback() {
    log "Откат изменений, внесённых скриптом..."
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
    if timeout 5 ip route show default 2>/dev/null | grep -q 'via'; then
        return 0
    fi
    log "  маршрут по умолчанию через WAN отсутствует — ждём 10с, netifd должен восстановить"
    sleep 10
    if timeout 5 ip route show default 2>/dev/null | grep -q 'via'; then
        log "  маршрут восстановлен netifd"
    else
        log "  ВНИМАНИЕ: маршрут так и не появился — проверьте WAN вручную"
    fi
}

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
        log "  создана зона $AWG_ZONE_NAME (index $idx)"
    else
        log "  зона $AWG_ZONE_NAME уже существует (index $idx)"
    fi

    if ! uci -q get firewall.@zone[$idx].network 2>/dev/null | grep -qw 'awg'; then
        uci add_list firewall.@zone[$idx].network='awg'
        log "  зона $AWG_ZONE_NAME привязана к интерфейсу awg"
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
        log "  добавлен forwarding lan -> $AWG_ZONE_NAME"
    elif [ "$count" -gt 1 ]; then
        first=1
        for i in $indices; do
            if [ "$first" = "1" ]; then
                first=0
                continue
            fi
            uci delete firewall.@forwarding[$i]
            log "  удалён дубль forwarding[$i]"
        done
    else
        log "  forwarding lan -> $AWG_ZONE_NAME уже есть (1 шт.)"
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
        log "  ожидание handshake... ${elapsed}s"
    done
    return 1
}

# ==================== 0. СКАЧИВАНИЕ СПИСКА (ДО ЛЮБЫХ ИЗМЕНЕНИЙ) ====================
log "0. Скачивание списка (до изменений сети, пока WAN-маршрут точно есть)..."
rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"
fetch_list "$TMP_RAW" || die "не удалось скачать список ни с одного зеркала (WAN/DNS?)"

# ==================== 1. ПРОВЕРКА ====================
log "1. Проверка окружения..."
[ -f /etc/iproute2/rt_tables ] || die "/etc/iproute2/rt_tables не найден"
command -v nft >/dev/null 2>&1 || die "nft не найден (нужен fw4/nftables)"
command -v uci >/dev/null 2>&1 || die "uci не найден"
command -v awg >/dev/null 2>&1 || die "awg не найден (amneziawg-tools)"
uci -q get network.awg >/dev/null 2>&1 || die "network.awg не настроен — сначала настройте AmneziaWG в LuCI"
log "  базовые проверки пройдены"

# ==================== 2. HANDSHAKE ====================
log "2. Обеспечение handshake..."
# PersistentKeepalive — удерживает NAT-привязку, чтобы handshake не пропадал без route_allowed_ips
if [ -z "$(uci -q get network.@amneziawg_awg[0].persistent_keepalive 2>/dev/null)" ]; then
    uci set network.@amneziawg_awg[0].persistent_keepalive="$KEEPALIVE"
    log "  persistent_keepalive=$KEEPALIVE"
fi

uci set network.@amneziawg_awg[0].route_allowed_ips='1'
uci commit network
ifup awg >/dev/null 2>&1 || true
log "  route_allowed_ips=1, ifup awg, ждём handshake..."

if ! wait_handshake; then
    log "ВНИМАНИЕ: handshake не появился за ${HANDSHAKE_TIMEOUT}s."
    log "  Проверьте: ключи, параметры обфускации (jc/jmin/jmax/s1/s2/h1-h4/i1),"
    log "  endpoint, системное время, доступность UDP."
    log "  Скрипт продолжит, но маршрут в table $RT_TABLE_ID может не работать."
else
    log "  handshake появился, туннель активен"
fi

# ==================== 3. ПАРСИНГ (список уже скачан) ====================
log "3. Парсинг списка..."
parse_list "$TMP_RAW" "$TMP_IPS" || die "не удалось получить ни одного IP"
IP_COUNT=$(wc -l < "$TMP_IPS" 2>/dev/null || echo 0)
log "  получено IP/CIDR: $IP_COUNT"

# ==================== 4. NFT ====================
log "4. Генерация nft-конфига..."
gen_nft "$TMP_IPS" "$TMP_NFT" || die "не удалось сгенерировать nft-конфиг"
cp "$TMP_NFT" "$NFT_FILE"

# ==================== 5. UCI (ЗОНА, FORWARDING, ПРАВИЛО, INCLUDE) ====================
log "5. Применение uci-настроек..."

grep -q "$RT_TABLE_ID $RT_TABLE_NAME" /etc/iproute2/rt_tables \
    || echo "$RT_TABLE_ID $RT_TABLE_NAME" >> /etc/iproute2/rt_tables

if [ "$(uci -q get network.awg.auto)" != "1" ]; then
    uci set network.awg.auto='1'
    log "  network.awg.auto=1"
fi

ZONE_IDX=$(ensure_awg_zone)
log "  зона awg: index $ZONE_IDX"

ensure_forwarding

uci -q delete network.awg_rule 2>/dev/null || true
uci set network.awg_rule=rule
uci set network.awg_rule.mark="$FWMARK"
uci set network.awg_rule.lookup="$RT_TABLE_ID"

uci -q delete firewall.$NFT_INCLUDE_NAME 2>/dev/null || true
uci set firewall.$NFT_INCLUDE_NAME=include
uci set firewall.$NFT_INCLUDE_NAME.type='nftables'
uci set firewall.$NFT_INCLUDE_NAME.path="$NFT_FILE"
uci set firewall.$NFT_INCLUDE_NAME.position='table-append'

uci commit network
uci commit firewall

/etc/init.d/firewall restart >/dev/null 2>&1 || log "ВНИМАНИЕ: firewall restart вернул ошибку"
/etc/init.d/network reload   >/dev/null 2>&1 || log "ВНИМАНИЕ: network reload вернул ошибку"

# ==================== 6. ПОДЪЁМ AWG И UCI-МАРШРУТ В TABLE 100 ====================
log "6. Подъём awg и маршрут в таблице $RT_TABLE_ID..."
ifup awg >/dev/null 2>&1 || true
sleep 3
if ip link show awg >/dev/null 2>&1; then
    # Создаём UCI-маршрут в table 100 (netifd будет управлять им постоянно)
    uci -q delete network.awg_route 2>/dev/null || true
    uci set network.awg_route=route
    uci set network.awg_route.interface='awg'
    uci set network.awg_route.target='0.0.0.0/0'
    uci set network.awg_route.table="$RT_TABLE_ID"
    uci commit network
    /etc/init.d/network reload >/dev/null 2>&1 || true
    sleep 2
    log "  UCI-маршрут в table $RT_TABLE_ID создан"
else
    log "  ВНИМАНИЕ: awg не поднят — маршрут не создан"
fi

# ==================== 7. СНЯТИЕ ГАЛОЧКИ ====================
log "7. Снятие route_allowed_ips (галочки)..."
uci set network.@amneziawg_awg[0].route_allowed_ips='0'
uci commit network

log "  route_allowed_ips=0, ifup wan, ifup awg, ждём handshake (до ${HANDSHAKE_TIMEOUT}s)..."
ifup wan >/dev/null 2>&1 || true
sleep 3
ensure_wan_default
ifup awg >/dev/null 2>&1 || true

if wait_handshake; then
    log "  handshake сохранился — выборочная маршрутизация активна"

    # Убеждаемся, что UCI-правило применено netifd
    if ! ip rule show | grep -q "fwmark $FWMARK lookup $RT_TABLE_ID"; then
        log "  правило fwmark не найдено — перезапускаю network"
        /etc/init.d/network reload >/dev/null 2>&1 || true
        sleep 3
        if ! ip rule show | grep -q "fwmark $FWMARK lookup $RT_TABLE_ID"; then
            log "  правило всё ещё не найдено — добавляю вручную"
            ip rule add fwmark "$FWMARK" lookup "$RT_TABLE_ID" 2>/dev/null || true
        fi
    fi

    # Убеждаемся, что маршрут в table 100 есть
    if ip link show awg >/dev/null 2>&1; then
        if ! ip route show table "$RT_TABLE_ID" 2>/dev/null | grep -q '^default'; then
            log "  маршрут в table $RT_TABLE_ID отсутствует — создаю вручную"
            ip route replace default dev awg table "$RT_TABLE_ID" 2>/dev/null || true
        fi
    fi

    # Перезапускаем dnsmasq ВСЕГДА после ifup wan (сокет мог стать невалидным)
    log "  перезапускаю dnsmasq после ifup wan"
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    sleep 2
else
    log "  ВНИМАНИЕ: handshake не появился за ${HANDSHAKE_TIMEOUT}s после снятия галочки."
    log "  На этой прошивке выборочная маршрутизация невозможна."
    log "  Возвращаю route_allowed_ips=1 (полный туннель)..."
    uci set network.@amneziawg_awg[0].route_allowed_ips='1'
    uci commit network
    ifup wan >/dev/null 2>&1 || true
    sleep 3
    ensure_wan_default
    ifup awg >/dev/null 2>&1 || true
    if wait_handshake; then
        log "  полный туннель восстановлен, handshake есть"
    else
        log "  ВНИМАНИЕ: handshake не восстановился и в полном туннеле."
        log "  Проверьте: awg show, logread | grep -i awg, ping endpoint."
    fi
fi

# ==================== 8. UPDATE-СКРИПТ ====================
log "8. Установка $UPDATE_SCRIPT..."
cat > "$UPDATE_SCRIPT" << 'UPD_EOF'
#!/bin/sh
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
# восстановление маршрута и правила после перезагрузки (netifd может не успеть)
sed -i '\|ip route replace default dev awg table '"$RT_TABLE_ID"'|d' /etc/crontabs/root
echo "@reboot sleep 30 && ip route replace default dev awg table $RT_TABLE_ID" >> /etc/crontabs/root
sed -i '\|ip rule add fwmark '"$FWMARK"' lookup '"$RT_TABLE_ID"'|d' /etc/crontabs/root
echo "@reboot sleep 32 && ip rule add fwmark $FWMARK lookup $RT_TABLE_ID 2>/dev/null || true" >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart

log "Готово. Список: $IP_COUNT IP. Зона awg, forwarding, nft-set, fwmark -> table $RT_TABLE_ID настроены."
log "Маршрут в table $RT_TABLE_ID: $(ip route show table $RT_TABLE_ID 2>/dev/null | head -1)"
log "Правило fwmark: $(ip rule show 2>/dev/null | grep "fwmark $FWMARK lookup $RT_TABLE_ID" | head -1)"
log "Проверка: sh /usr/bin/check_vpn.sh"