
#!/bin/sh
# check_vpn.sh — диагностика AmneziaWG

RT_TABLE_ID="100"
FWMARK="0x1"
NFT_FILE="/etc/nftables.d/99-awg-domains.nft"
NFT_INCLUDE_NAME="awg_domains"
UPDATE_SCRIPT="/usr/bin/update_awg_domains.sh"

ok=0
fail=0
warn=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

pass() {
    green "[OK]   $*"
    ok=$((ok+1))
}

err() {
    red "[FAIL] $*"
    fail=$((fail+1))
}

warn_() {
    yellow "[WARN] $*"
    warn=$((warn+1))
}

echo "=========================================="
echo " Диагностика AmneziaWG"
echo "=========================================="

# ---------- 1. ENVIRONMENT ----------

echo
echo "--- 1. Окружение ---"

command -v nft >/dev/null 2>&1 &&
    pass "nft найден" || err "nft не найден"

command -v uci >/dev/null 2>&1 &&
    pass "uci найден" || err "uci не найден"

[ -f /etc/iproute2/rt_tables ] &&
    pass "rt_tables существует" || err "rt_tables отсутствует"

grep -q "$RT_TABLE_ID " /etc/iproute2/rt_tables 2>/dev/null &&
    pass "Таблица 100 зарегистрирована" ||
    warn_ "Таблица 100 не зарегистрирована"

# ---------- 2. UCI AWG ----------

echo
echo "--- 2. UCI network.awg ---"

if uci -q get network.awg >/dev/null 2>&1; then

    pass "network.awg настроен"

    [ "$(uci -q get network.awg.proto)" = "amneziawg" ] &&
        pass "proto=amneziawg" ||
        err "Неверный proto"

    [ "$(uci -q get network.awg.auto)" = "1" ] &&
        pass "auto=1" ||
        warn_ "auto не равен 1"

else
    err "network.awg отсутствует"
fi

# ---------- 3. INTERFACE ----------

echo
echo "--- 3. Интерфейс awg ---"

if ip link show awg >/dev/null 2>&1; then

    pass "Интерфейс awg существует"

    ip -4 addr show awg | grep -q 'inet ' &&
        pass "AWG имеет IPv4" ||
        warn_ "AWG не имеет IPv4"

    state=$(ip link show awg | awk '/state/ {print $9}')

    [ "$state" = "UNKNOWN" ] || [ "$state" = "UP" ] &&
        pass "state=$state" ||
        warn_ "state=$state"

else
    err "Интерфейс awg отсутствует"
fi

if command -v awg >/dev/null 2>&1; then

    handshake=$(awg show 2>/dev/null | awk '/latest handshake/ {print $0}')

    if [ -n "$handshake" ]; then
        pass "Handshake: $handshake"
    else
        warn_ "Нет handshake"
    fi

    rx=$(awg show 2>/dev/null | awk '/transfer/ {print $3, $4}')

    [ -n "$rx" ] &&
        pass "Transfer: $rx" ||
        warn_ "Transfer пуст"

fi

# ---------- 4. FIREWALL ZONE ----------

echo
echo "--- 4. Firewall zone awg ---"

idx=""

for i in $(uci show firewall 2>/dev/null |
    grep -oE '@zone\[[0-9]+\]=zone' |
    grep -oE '[0-9]+'); do

    if [ "$(uci -q get firewall.@zone[$i].name)" = "awg" ]; then
        idx="$i"
        break
    fi
done

if [ -n "$idx" ]; then

    pass "Зона awg существует"

    uci -q get firewall.@zone[$idx].network 2>/dev/null |
        grep -qw 'awg' &&
        pass "zone.network содержит awg" ||
        err "zone.network не содержит awg"

    [ "$(uci -q get firewall.@zone[$idx].masq)" = "1" ] &&
        pass "masq=1" ||
        warn_ "masq не включён"

    [ "$(uci -q get firewall.@zone[$idx].mtu_fix)" = "1" ] &&
        pass "mtu_fix=1" ||
        warn_ "mtu_fix не включён"

else
    err "Зона awg не найдена"
fi

# ---------- 5. FORWARDING ----------

echo
echo "--- 5. Forwarding LAN -> AWG ---"

cnt=0

for i in $(uci show firewall 2>/dev/null |
    grep -oE '@forwarding\[[0-9]+\]=forwarding' |
    grep -oE '[0-9]+'); do

    if [ "$(uci -q get firewall.@forwarding[$i].dest)" = "awg" ]; then
        cnt=$((cnt+1))
    fi
done

if [ "$cnt" -eq 1 ]; then
    pass "Forwarding lan -> awg существует"
elif [ "$cnt" -eq 0 ]; then
    err "Forwarding отсутствует"
else
    warn_ "Обнаружены дубли forwarding: $cnt"
fi

if nft list chain inet fw4 forward_lan 2>/dev/null |
    grep -q 'accept_to_awg\|oifname "awg" accept'; then

    pass "fw4 создал accept_to_awg"

else
    err "fw4 не создал accept_to_awg"
fi

# ---------- 6. POLICY ROUTING ----------

echo
echo "--- 6. fwmark -> table 100 ---"

if [ -x /usr/bin/ensure_awg_policy.sh ]; then
    pass "Policy helper установлен"
else
    warn_ "Policy helper отсутствует"
fi

RULE_LINE=$(ip -4 rule show 2>/dev/null |
    grep -E "fwmark $FWMARK([ /]|$).*lookup (100|awg_vpn)([[:space:]]|$)" |
    head -1)

if [ -n "$RULE_LINE" ]; then
    pass "Правило fwmark существует"
    echo "       $RULE_LINE"
else
    warn_ "Правило fwmark отсутствует"
    ip -4 rule show
fi

# ---------- 7. ROUTES ----------

echo
echo "--- 7. Маршруты ---"

MAIN_DEFAULT=$(ip -4 route show table main default 2>/dev/null)

if echo "$MAIN_DEFAULT" | grep -q 'dev awg'; then
    pass "Main default через AWG"

elif [ -n "$MAIN_DEFAULT" ]; then
    pass "Main default остаётся через WAN"
    echo "$MAIN_DEFAULT"

else
    err "В main отсутствует default-маршрут"
fi

TABLE_ROUTE=$(ip -4 route show table "$RT_TABLE_ID" 2>/dev/null |
    grep '^default' | head -1)

if echo "$TABLE_ROUTE" | grep -q 'dev awg'; then
    pass "Default в table 100 через AWG"
else
    warn_ "Default в table 100 отсутствует или неверен"
    [ -n "$TABLE_ROUTE" ] && echo "$TABLE_ROUTE"
fi

# ---------- 8. NFTABLES ----------

echo
echo "--- 8. nftables ---"

if nft list set inet fw4 vpn_domains >/dev/null 2>&1; then

    pass "vpn_domains существует"

    cnt=$(nft list set inet fw4 vpn_domains 2>/dev/null |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' |
        wc -l)

    [ "$cnt" -gt 0 ] &&
        pass "IP в set: $cnt" ||
        err "Set пуст"

else
    warn_ "vpn_domains не найден"
fi

if nft list chain inet fw4 mangle_prerouting_awg >/dev/null 2>&1; then
    pass "mangle_prerouting_awg существует"
else
    warn_ "mangle_prerouting_awg отсутствует"
fi

if uci -q get firewall.$NFT_INCLUDE_NAME >/dev/null 2>&1; then

    pass "UCI include настроен"

    path=$(uci -q get firewall.$NFT_INCLUDE_NAME.path)

    [ "$path" = "$NFT_FILE" ] &&
        pass "Путь include корректен" ||
        warn_ "Путь include неверен: $path"

else
    warn_ "UCI include отсутствует"
fi

# ---------- 9. ROUTE TEST ----------

echo
echo "--- 9. Проверка маршрутизации ---"

TEST_IP="142.250.74.46"

ip -4 route flush cache 2>/dev/null || true

ROUTE_TEST=$(ip -4 route get "$TEST_IP" mark "$FWMARK" 2>/dev/null || true)

if echo "$ROUTE_TEST" | grep -q 'dev awg'; then

    pass "Тестовый IP идёт через AWG"

else

    warn_ "Тестовый IP не идёт через AWG"
    echo "$ROUTE_TEST"

fi

# ---------- 10. UPDATE AND CRON ----------

echo
echo "--- 10. Update и cron ---"

[ -x "$UPDATE_SCRIPT" ] &&
    pass "Update script исполняемый" ||
    err "Update script отсутствует"

if [ -f /etc/crontabs/root ] &&
    grep -q "$UPDATE_SCRIPT" /etc/crontabs/root; then

    pass "Cron содержит update script"
    grep "$UPDATE_SCRIPT" /etc/crontabs/root

else
    err "Cron не содержит update script"
fi

pgrep -f crond >/dev/null 2>&1 &&
    pass "crond запущен" ||
    warn_ "crond не запущен"

[ -x /etc/hotplug.d/iface/95-awg-policy ] &&
    pass "Hotplug восстановления AWG установлен" ||
    warn_ "Hotplug отсутствует"

# ---------- 11. DNS ----------

echo
echo "--- 11. DNS / dnsmasq ---"

DNS_LOCAL_OUT=$(timeout 5 nslookup google.com 127.0.0.1 2>&1 || true)

DNS_RESULT=$(printf '%s\n' "$DNS_LOCAL_OUT" |
    awk '/^Name: / {found=1; next} found && /^Address [0-9]+: / {print $3; exit}')

if [ -n "$DNS_RESULT" ]; then

    pass "dnsmasq отвечает на 127.0.0.1:53"
    pass "google.com -> $DNS_RESULT"

else

    err "DNS через 127.0.0.1 не разрешил google.com"

    echo "$DNS_LOCAL_OUT"

    if command -v netstat >/dev/null 2>&1; then
        netstat -ln 2>/dev/null |
            grep -E '(:53[[:space:]]|:53$)'
    elif command -v ss >/dev/null 2>&1; then
        ss -ln 2>/dev/null | grep ':53'
    fi

    logread 2>/dev/null |
        grep -i dnsmasq |
        tail -10

fi

DNS_SYSTEM_OUT=$(timeout 5 nslookup google.com 2>&1 || true)

DNS_SYSTEM_RESULT=$(printf '%s\n' "$DNS_SYSTEM_OUT" |
    awk '/^Name: / {found=1; next} found && /^Address [0-9]+: / {print $3; exit}')

if [ -n "$DNS_SYSTEM_RESULT" ]; then
    pass "Системный DNS работает: $DNS_SYSTEM_RESULT"
else
    warn_ "Системный DNS не разрешает google.com"
fi

# ---------- 12. IPV6 ----------

echo
echo "--- 12. IPv6 LAN ---"

if [ -z "$(uci -q get network.lan.ip6assign)" ] &&
    [ "$(uci -q get network.lan.delegate)" = "0" ]; then

    pass "IPv6 LAN отключён"

else

    warn_ "IPv6 LAN может быть активен"

    echo "ip6assign=$(uci -q get network.lan.ip6assign)"
    echo "delegate=$(uci -q get network.lan.delegate)"

fi

# ---------- SUMMARY ----------

echo
echo "=========================================="
echo " ИТОГ: OK=$ok WARN=$warn FAIL=$fail"
echo "=========================================="

[ "$fail" -eq 0 ] && exit 0 || exit 1
