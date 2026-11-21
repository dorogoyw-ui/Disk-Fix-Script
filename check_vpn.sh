#!/bin/sh
# check_vpn.sh — диагностика policy routing для AmneziaWG
# Использование: sh /usr/bin/check_vpn.sh

RT_TABLE_ID="100"
FWMARK="0x1"
NFT_FILE="/etc/nftables.d/99-awg-domains.nft"
NFT_INCLUDE_NAME="awg_domains"
UPDATE_SCRIPT="/usr/bin/update_awg_domains.sh"

ok=0; fail=0; warn=0
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

pass() { green "[OK]   $*"; ok=$((ok+1)); }
err()  { red   "[FAIL] $*"; fail=$((fail+1)); }
warn_() { yellow "[WARN] $*"; warn=$((warn+1)); }

echo "=========================================="
echo " Диагностика AmneziaWG policy routing"
echo "=========================================="

# ---------- 1. Окружение ----------
echo
echo "--- 1. Окружение ---"
command -v nft >/dev/null 2>&1 && pass "nft найден" || err "nft не найден"
command -v uci >/dev/null 2>&1 && pass "uci найден" || err "uci не найден"
[ -f /etc/iproute2/rt_tables ] && pass "/etc/iproute2/rt_tables есть" || err "нет /etc/iproute2/rt_tables"
grep -q "$RT_TABLE_ID $RT_TABLE_NAME" /etc/iproute2/rt_tables 2>/dev/null \
    && pass "таблица $RT_TABLE_ID зарегистрирована как $RT_TABLE_NAME" \
    || warn_ "таблица $RT_TABLE_ID не зарегистрирована в rt_tables"

# ---------- 2. Интерфейс awg ----------
echo
echo "--- 2. Интерфейс awg ---"
if ip link show awg >/dev/null 2>&1; then
    pass "интерфейс awg существует"
    ip -4 addr show awg | grep -q 'inet ' && pass "awg имеет IPv4-адрес" || warn_ "awg без IPv4"
    state=$(ip link show awg | awk '/state/ {print $9}')
    [ "$state" = "UNKNOWN" ] || [ "$state" = "UP" ] && pass "awg state=$state" || warn_ "awg state=$state"
else
    err "интерфейс awg не существует"
fi

if uci -q get network.awg >/dev/null 2>&1; then
    pass "uci network.awg настроен"
    rai=$(uci -q get network.@wireguard_awg[0].route_allowed_ips 2>/dev/null)
    [ "$rai" = "1" ] && pass "route_allowed_ips=1" || warn_ "route_allowed_ips='$rai' (ожидалось 1)"
else
    err "uci network.awg отсутствует"
fi

# ---------- 3. Правило fwmark ----------
echo
echo "--- 3. Правило fwmark -> table $RT_TABLE_ID ---"
if uci -q get network.awg_rule >/dev/null 2>&1; then
    pass "uci network.awg_rule существует"
else
    err "uci network.awg_rule отсутствует"
fi
if ip rule show | grep -q "fwmark $FWMARK lookup $RT_TABLE_ID"; then
    pass "ip rule: fwmark $FWMARK -> table $RT_TABLE_ID"
else
    err "ip rule: fwmark $FWMARK -> table $RT_TABLE_ID не найдено"
fi

# ---------- 4. Маршрут в таблице 100 ----------
echo
echo "--- 4. Маршрут в таблице $RT_TABLE_ID ---"
if ip route show table "$RT_TABLE_ID" 2>/dev/null | grep -q '^default'; then
    pass "default в table $RT_TABLE_ID есть:"
    ip route show table "$RT_TABLE_ID" | sed 's/^/       /'
else
    err "default в table $RT_TABLE_ID отсутствует"
fi

# ---------- 5. nft-набор ----------
echo
echo "--- 5. nftables ---"
if nft list set inet fw4 vpn_domains >/dev/null 2>&1; then
    pass "nft set inet fw4 vpn_domains существует"
    cnt=$(nft list set inet fw4 vpn_domains 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | wc -l)
    [ "$cnt" -gt 0 ] && pass "  элементов в set: $cnt" || err "  set пуст"
else
    err "nft set inet fw4 vpn_domains не найден"
fi
if nft list chain inet fw4 mangle_prerouting_awg >/dev/null 2>&1; then
    pass "nft chain mangle_prerouting_awg существует"
else
    err "nft chain mangle_prerouting_awg не найден"
fi
if uci -q get firewall.$NFT_INCLUDE_NAME >/dev/null 2>&1; then
    pass "uci firewall.$NFT_INCLUDE_NAME (include) настроен"
    path=$(uci -q get firewall.$NFT_INCLUDE_NAME.path)
    [ "$path" = "$NFT_FILE" ] && pass "  path=$NFT_FILE" || warn_ "  path=$path (ожидалось $NFT_FILE)"
else
    err "uci firewall.$NFT_INCLUDE_NAME отсутствует"
fi

# ---------- 6. Проверка маркировки ----------
echo
echo "--- 6. Маркировка и маршрут для тестового IP ---"
TEST_IP="142.250.74.46"
if ip route get "$TEST_IP" mark "$FWMARK" 2>/dev/null | grep -q 'dev awg'; then
    pass "ip route get $TEST_IP mark $FWMARK -> dev awg"
else
    err "ip route get $TEST_IP mark $FWMARK не идёт через awg"
    ip route get "$TEST_IP" mark "$FWMARK" 2>/dev/null | sed 's/^/       /'
fi

# ---------- 7. Update-скрипт и cron ----------
echo
echo "--- 7. Update-скрипт и cron ---"
[ -x "$UPDATE_SCRIPT" ] && pass "$UPDATE_SCRIPT исполняемый" || err "$UPDATE_SCRIPT отсутствует или не исполняемый"
if [ -f /etc/crontabs/root ] && grep -q "$UPDATE_SCRIPT" /etc/crontabs/root; then
    pass "cron содержит $UPDATE_SCRIPT:"
    grep "$UPDATE_SCRIPT" /etc/crontabs/root | sed 's/^/       /'
else
    err "cron не содержит $UPDATE_SCRIPT"
fi
pgrep -f "crond" >/dev/null 2>&1 && pass "crond запущен" || warn_ "crond не запущен"

# ---------- 8. dnsmasq ----------
echo
echo "--- 8. dnsmasq ---"
if timeout 5 nslookup google.com >/dev/null 2>&1; then
    pass "dnsmasq отвечает на google.com"
    ip=$(timeout 5 nslookup google.com 2>/dev/null | awk '/^Address [0-9]+: / {print $3}' | head -1)
    [ -n "$ip" ] && pass "  google.com -> $ip" || warn_ "  не удалось извлечь IP"
else
    err "dnsmasq не отвечает на google.com"
fi

# ---------- 9. Счётчики awg ----------
echo
echo "--- 9. Счётчики awg ---"
if ip link show awg >/dev/null 2>&1; then
    rx=$(ip -s link show awg 2>/dev/null | awk '/RX:/ {getline; print $2}')
    tx=$(ip -s link show awg 2>/dev/null | awk '/TX:/ {getline; print $2}')
    [ "${rx:-0}" -gt 0 ] 2>/dev/null && pass "RX=$rx байт" || warn_ "RX=$rx (нет входящего трафика)"
    [ "${tx:-0}" -gt 0 ] 2>/dev/null && pass "TX=$tx байт" || warn_ "TX=$tx (нет исходящего трафика)"
fi

# ---------- Итог ----------
echo
echo "=========================================="
echo " ИТОГ: OK=$ok  WARN=$warn  FAIL=$fail"
echo "=========================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1