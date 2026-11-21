#!/bin/sh
# check_vpn.sh — диагностика AmneziaWG: полный туннель + policy routing
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
echo " Диагностика AmneziaWG"
echo "=========================================="

# ---------- 1. Окружение ----------
echo
echo "--- 1. Окружение ---"
command -v nft >/dev/null 2>&1 && pass "nft найден" || err "nft не найден"
command -v uci >/dev/null 2>&1 && pass "uci найден" || err "uci не найден"
[ -f /etc/iproute2/rt_tables ] && pass "/etc/iproute2/rt_tables есть" || err "нет /etc/iproute2/rt_tables"
grep -q "$RT_TABLE_ID " /etc/iproute2/rt_tables 2>/dev/null \
    && pass "таблица $RT_TABLE_ID зарегистрирована" \
    || warn_ "таблица $RT_TABLE_ID не зарегистрирована в rt_tables"

# ---------- 2. UCI awg ----------
echo
echo "--- 2. UCI network.awg ---"
if uci -q get network.awg >/dev/null 2>&1; then
    pass "network.awg настроен"
    [ "$(uci -q get network.awg.proto)" = "amneziawg" ] && pass "  proto=amneziawg" || err "  proto=$(uci -q get network.awg.proto)"
    [ "$(uci -q get network.awg.auto)" = "1" ] && pass "  auto=1" || warn_ "  auto=$(uci -q get network.awg.auto) (ожидалось 1)"
else
    err "network.awg отсутствует"
fi

# ---------- 3. Интерфейс awg ----------
echo
echo "--- 3. Интерфейс awg ---"
if ip link show awg >/dev/null 2>&1; then
    pass "интерфейс awg существует"
    ip -4 addr show awg | grep -q 'inet ' && pass "  awg имеет IPv4" || warn_ "  awg без IPv4"
    state=$(ip link show awg | awk '/state/ {print $9}')
    [ "$state" = "UNKNOWN" ] || [ "$state" = "UP" ] && pass "  state=$state" || warn_ "  state=$state"
else
    err "интерфейс awg не существует (ifup awg)"
fi
if command -v awg >/dev/null 2>&1; then
    handshake=$(awg show 2>/dev/null | awk '/latest handshake/ {print $0}')
    if [ -n "$handshake" ]; then
        pass "awg handshake: $handshake"
    else
        warn_ "awg: нет handshake (проверьте параметры обфускации/время)"
    fi
    rx=$(awg show 2>/dev/null | awk '/transfer/ {print $3, $4}')
    [ -n "$rx" ] && pass "awg transfer: $rx" || warn_ "awg: transfer пуст"
fi

# ---------- 4. Зона firewall ----------
echo
echo "--- 4. Зона firewall awg ---"
idx=""
for i in $(uci show firewall 2>/dev/null | grep -oE '@zone\[[0-9]+\]=zone' | grep -oE '[0-9]+'); do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "awg" ]; then
        idx="$i"
        break
    fi
done

if [ -n "$idx" ]; then
    pass "зона awg существует (index $idx)"
    uci -q get firewall.@zone[$idx].network 2>/dev/null | grep -qw 'awg' \
        && pass "  zone.network содержит awg" \
        || err "  zone.network НЕ содержит awg (добавьте: uci add_list firewall.@zone[$idx].network='awg')"
    [ "$(uci -q get firewall.@zone[$idx].masq)" = "1" ] && pass "  masq=1" || warn_ "  masq=$(uci -q get firewall.@zone[$idx].masq)"
    [ "$(uci -q get firewall.@zone[$idx].mtu_fix)" = "1" ] && pass "  mtu_fix=1" || warn_ "  mtu_fix=$(uci -q get firewall.@zone[$idx].mtu_fix)"
    [ "$(uci -q get firewall.@zone[$idx].forward)" = "ACCEPT" ] && pass "  forward=ACCEPT" || warn_ "  forward=$(uci -q get firewall.@zone[$idx].forward)"
else
    err "зона awg не найдена"
fi

# ---------- 5. Forwarding ----------
echo
echo "--- 5. Forwarding lan -> awg ---"
cnt=0
for i in $(uci show firewall 2>/dev/null | grep -oE '@forwarding\[[0-9]+\]=forwarding' | grep -oE '[0-9]+'); do
    if [ "$(uci -q get firewall.@forwarding[$i].dest)" = "awg" ]; then
        cnt=$((cnt+1))
    fi
done

if [ "$cnt" -eq 0 ]; then
    err "forwarding lan -> awg отсутствует"
elif [ "$cnt" -eq 1 ]; then
    pass "forwarding lan -> awg есть (1 шт.)"
else
    warn_ "forwarding lan -> awg: $cnt шт. (дубли, удалите лишние)"
fi

if nft list chain inet fw4 forward_lan 2>/dev/null | grep -q 'accept_to_awg\|oifname "awg" accept'; then
    pass "fw4 сгенерировал accept_to_awg в forward_lan"
else
    err "fw4 НЕ сгенерировал accept_to_awg (проверьте zone.network=awg и forwarding)"
fi

# ---------- 6. Правило fwmark ----------
echo
echo "--- 6. Правило fwmark -> table $RT_TABLE_ID ---"
if uci -q get network.awg_rule >/dev/null 2>&1; then
    pass "uci network.awg_rule существует"
else
    warn_ "uci network.awg_rule отсутствует (для выборочной маршрутизации)"
fi
if ip rule show | grep -q "fwmark $FWMARK lookup $RT_TABLE_ID"; then
    pass "ip rule: fwmark $FWMARK -> table $RT_TABLE_ID"
else
    warn_ "ip rule: fwmark $FWMARK -> table $RT_TABLE_ID не найдено"
fi

# ---------- 7. Маршруты ----------
echo
echo "--- 7. Маршруты ---"
if ip route show default 2>/dev/null | grep -q 'dev awg'; then
    pass "default (main) -> awg"
else
    warn_ "default (main) не через awg (route_allowed_ips?)"
    ip route show default 2>/dev/null | sed 's/^/       /'
fi
if ip route show table "$RT_TABLE_ID" 2>/dev/null | grep -q '^default'; then
    pass "default в table $RT_TABLE_ID есть"
else
    warn_ "default в table $RT_TABLE_ID отсутствует (создаст скрипт при ifup awg)"
fi

# ---------- 8. nftables ----------
echo
echo "--- 8. nftables ---"
if nft list set inet fw4 vpn_domains >/dev/null 2>&1; then
    pass "nft set inet fw4 vpn_domains существует"
    cnt=$(nft list set inet fw4 vpn_domains 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | wc -l)
    [ "$cnt" -gt 0 ] && pass "  элементов: $cnt" || err "  set пуст"
else
    warn_ "nft set inet fw4 vpn_domains не найден"
fi
if nft list chain inet fw4 mangle_prerouting_awg >/dev/null 2>&1; then
    pass "nft chain mangle_prerouting_awg существует"
else
    warn_ "nft chain mangle_prerouting_awg не найден"
fi
if uci -q get firewall.$NFT_INCLUDE_NAME >/dev/null 2>&1; then
    pass "uci firewall.$NFT_INCLUDE_NAME настроен"
    path=$(uci -q get firewall.$NFT_INCLUDE_NAME.path)
    [ "$path" = "$NFT_FILE" ] && pass "  path=$NFT_FILE" || warn_ "  path=$path"
else
    warn_ "uci firewall.$NFT_INCLUDE_NAME отсутствует"
fi

# ---------- 9. Проверка маркировки ----------
echo
echo "--- 9. Маркировка тестового IP ---"
TEST_IP="142.250.74.46"
if ip route get "$TEST_IP" mark "$FWMARK" 2>/dev/null | grep -q 'dev awg'; then
    pass "ip route get $TEST_IP mark $FWMARK -> dev awg"
else
    warn_ "ip route get $TEST_IP mark $FWMARK не через awg"
    ip route get "$TEST_IP" mark "$FWMARK" 2>/dev/null | sed 's/^/       /'
fi

# ---------- 10. Update-скрипт и cron ----------
echo
echo "--- 10. Update-скрипт и cron ---"
[ -x "$UPDATE_SCRIPT" ] && pass "$UPDATE_SCRIPT исполняемый" || err "$UPDATE_SCRIPT отсутствует"
if [ -f /etc/crontabs/root ] && grep -q "$UPDATE_SCRIPT" /etc/crontabs/root; then
    pass "cron содержит $UPDATE_SCRIPT"
    grep "$UPDATE_SCRIPT" /etc/crontabs/root | sed 's/^/       /'
else
    err "cron не содержит $UPDATE_SCRIPT"
fi
pgrep -f crond >/dev/null 2>&1 && pass "crond запущен" || warn_ "crond не запущен"

# ---------- 11. DNS ----------
echo
echo "--- 11. dnsmasq ---"
if timeout 5 nslookup google.com >/dev/null 2>&1; then
    pass "dnsmasq отвечает"
    ip=$(timeout 5 nslookup google.com 2>/dev/null | awk '/^Address [0-9]+: / {print $3}' | head -1)
    [ -n "$ip" ] && pass "  google.com -> $ip"
else
    err "dnsmasq не отвечает"
fi

# ---------- 12. IPv6 на LAN ----------
echo
echo "--- 12. IPv6 на LAN ---"
if [ -z "$(uci -q get network.lan.ip6assign)" ] && [ "$(uci -q get network.lan.delegate)" = "0" ]; then
    pass "IPv6 на LAN отключён (ip6assign='', delegate=0)"
else
    warn_ "IPv6 на LAN может быть активен (ip6assign=$(uci -q get network.lan.ip6assign), delegate=$(uci -q get network.lan.delegate))"
fi

# ---------- Итог ----------
echo
echo "=========================================="
echo " ИТОГ: OK=$ok  WARN=$warn  FAIL=$fail"
echo "=========================================="
[ "$fail" -eq 0 ] && exit 0 || exit 1