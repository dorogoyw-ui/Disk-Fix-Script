#!/bin/sh
# setup_vpn_fixed.sh — с LIST_URL на GitHub + fallback на зеркала

set -e

# ---------- КОНФИГ ----------
LIST_URL="https://raw.githubusercontent.com/dorogoyw-ui/Disk-Fix-Script/main/list"
# Зеркала на случай блокировки raw.githubusercontent.com
LIST_MIRRORS="
https://cdn.jsdelivr.net/gh/dorogoyw-ui/Disk-Fix-Script@main/list
https://ghproxy.net/https://raw.githubusercontent.com/dorogoyw-ui/Disk-Fix-Script/main/list
https://raw.gitmirror.com/dorogoyw-ui/Disk-Fix-Script/main/list
"
UPDATE_SCRIPT="/usr/bin/update_awg_domains.sh"
RT_TABLE_ID="100"
RT_TABLE_NAME="awg_vpn"
FWMARK="0x1"

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

# ---------- 1. Проверка окружения ----------
log "1. Проверка окружения..."
[ -f /etc/iproute2/rt_tables ] || die "/etc/iproute2/rt_tables не найден"
command -v nft >/dev/null 2>&1 || die "nft не найден (нужен fw4/nftables)"
command -v uci >/dev/null 2>&1 || die "uci не найден"
uci -q get network.awg >/dev/null 2>&1 || \
    log "ВНИМАНИЕ: интерфейс 'awg' не найден в UCI — маршрут в таблицу $RT_TABLE_ID может не работать"

# ---------- 2. Скачивание списка (с зеркалами) ----------
log "2. Скачивание списка..."
TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"
FINAL_NFT="/etc/nftables.d/99-awg-domains.nft"

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"

fetch() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --connect-timeout 15 --max-time 120 -o "$TMP_RAW" "$url"
    else
        wget -4 -q -T 120 -O "$TMP_RAW" "$url"
    fi
}

ok=0
for url in "$LIST_URL" $LIST_MIRRORS; do
    [ -z "$url" ] && continue
    log "  пробую: $url"
    if fetch "$url" && [ -s "$TMP_RAW" ]; then
        log "  успешно: $url"
        ok=1
        break
    fi
    rm -f "$TMP_RAW"
done
[ "$ok" = "1" ] || die "не удалось скачать список ни с основного URL, ни с зеркал (DNS/DPI?)"

# ---------- 3. Парсинг ----------
log "3. Парсинг списка..."
ENTRIES=$(sed 's/\r//g; s/#.*//g; s/^[[:space:]]*//; s/[[:space:]]*$//' "$TMP_RAW" | grep -v '^$')
[ -n "$ENTRIES" ] || die "после очистки список пуст"

> "$TMP_IPS"
echo "$ENTRIES" | while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if echo "$entry" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'; then
        echo "$entry" >> "$TMP_IPS"
    else
        for sub in "$entry" "www.$entry"; do
            nslookup "$sub" 1.1.1.1 2>/dev/null \
                | awk '/^Address [0-9]+: / {print $3}' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$TMP_IPS" || true
        done
    fi
done

SORTED_IPS=$(sort -u "$TMP_IPS" | tr '\n' ',' | sed 's/,$//')
[ -n "$SORTED_IPS" ] || die "не удалось получить ни одного IP (DNS-резолвинг не работает?)"

# ---------- 4. Генерация nft ----------
log "4. Генерация nft-конфига..."
cat > "$TMP_NFT" << NFT_EOF
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

# ---------- 5. Применение сетевых правил ----------
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
/etc/init.d/network reload >/dev/null 2>&1 || log "ВНИМАНИЕ: network reload вернул ошибку"

# ---------- 6. Установка скрипта обновления ----------
log "6. Установка $UPDATE_SCRIPT..."
cat > "$UPDATE_SCRIPT" << 'UPD_EOF'
#!/bin/sh
# update_awg_domains.sh — обновление списка и nft-сета
LIST_URL="__LIST_URL__"
LIST_MIRRORS="__MIRRORS__"
TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"
FINAL_NFT="/etc/nftables.d/99-awg-domains.nft"

log() { logger -t awg-updater "$*"; }

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"

fetch() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL --connect-timeout 15 --max-time 180 -o "$TMP_RAW" "$url"
    else
        wget -4 -q -T 180 -O "$TMP_RAW" "$url"
    fi
}

ok=0
for url in "$LIST_URL" $LIST_MIRRORS; do
    [ -z "$url" ] && continue
    if fetch "$url" && [ -s "$TMP_RAW" ]; then ok=1; break; fi
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
        for sub in "$entry" "www.$entry"; do
            nslookup "$sub" 1.1.1.1 2>/dev/null \
                | awk '/^Address [0-9]+: / {print $3}' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >> "$TMP_IPS" || true
        done
    fi
done

SORTED_IPS=$(sort -u "$TMP_IPS" | tr '\n' ',' | sed 's/,$//')
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
    log "updated, firewall restarted"
else
    log "no changes"
fi

rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_NFT"
UPD_EOF

# подстановка URL и зеркал в скрипт обновления
sed -i "s|__LIST_URL__|$LIST_URL|" "$UPDATE_SCRIPT"
# зеркала — многострочные, поэтому подставляем через awk
MIRRORS_ONELINE=$(echo "$LIST_MIRRORS" | tr '\n' ' ')
sed -i "s|__MIRRORS__|$MIRRORS_ONELINE|" "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"

# ---------- 7. Cron ----------
log "7. Настройка cron (04:00 ежедневно)..."
mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i "\|$UPDATE_SCRIPT|d" /etc/crontabs/root
echo "0 4 * * * $UPDATE_SCRIPT" >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart

log "Готово. Список загружен ($(wc -l < "$TMP_IPS" 2>/dev/null || echo '?') IP), правила применены."