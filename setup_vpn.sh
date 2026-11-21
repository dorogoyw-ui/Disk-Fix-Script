#!/bin/sh

# ВСТАВЬТЕ СЮДА ПРЯМУЮ ССЫЛКУ НА ФАЙЛ list ИЗ OPENLIST (с /d/ и ?sign=...)
LIST_URL="http://qsqs.duckdns.org/d/guest/share/Soft/Amnezia/list?sign=SYr82ljLcBIgy4hWnpsQVowfDs4IS6ZxZULP4e0H96Q=:0"
UPDATE_SCRIPT="/usr/bin/update_awg_domains.sh"

echo "1. Настройка таблицы маршрутизации (таблица 100 -> awg)..."
grep -q "100 awg_vpn" /etc/iproute2/rt_tables || echo "100 awg_vpn" >> /etc/iproute2/rt_tables

uci -q delete network.awg_route
uci set network.awg_route=route
uci set network.awg_route.interface='awg'
uci set network.awg_route.target='0.0.0.0/0'
uci set network.awg_route.table='100'

uci -q delete network.awg_rule
uci set network.awg_rule=rule
uci set network.awg_rule.mark='0x1'
uci set network.awg_rule.lookup='100'
uci commit network

echo "2. Создание лёгкого скрипта обновления (поддержка доменов и IP-подсетей)..."
cat << EOF > "$UPDATE_SCRIPT"
#!/bin/sh

URL="$LIST_URL"
TMP_RAW="/tmp/awg_list.raw"
TMP_IPS="/tmp/awg_ips.tmp"
TMP_NFT="/tmp/99-awg-domains.nft"
FINAL_NFT="/etc/nftables.d/99-awg-domains.nft"

# Скачиваем список встроенным wget с таймаутом 15 секунд
if ! wget -q -T 15 -O "\$TMP_RAW" "\$URL"; then
    logger -t awg-updater "Ошибка: не удалось скачать список с \$URL"
    exit 1
fi

# Очищаем от пробелов, пустых строк, комментариев (#) и символов \r
ENTRIES=\$(sed 's/\r//g; s/#.*//g; s/^[[:space:]]*//; s/[[:space:]]*$//' "\$TMP_RAW" | grep -v '^$')

if [ -z "\$ENTRIES" ]; then
    logger -t awg-updater "Ошибка: скачанный список пуст или некорректен"
    rm -f "\$TMP_RAW"
    exit 1
fi

> "\$TMP_IPS"

# Разбираем каждую строку: либо готовый IP/CIDR, либо домен для резолвинга
for entry in \$ENTRIES; do
    if echo "\$entry" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?\$'; then
        echo "\$entry" >> "\$TMP_IPS"
    else
        for sub in "\$entry" "www.\$entry"; do
            nslookup "\$sub" 1.1.1.1 2>/dev/null | awk '/^Address [0-9]+: / {print \$3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\$' >> "\$TMP_IPS"
        done
    fi
done

# Удаляем дубликаты и форматируем через запятую для nftables
SORTED_IPS=\$(sort -u "\$TMP_IPS" | tr '\n' ',' | sed 's/,\$//')

if [ -z "\$SORTED_IPS" ]; then
    logger -t awg-updater "Ошибка: не удалось получить ни одного IP-адреса"
    rm -f "\$TMP_RAW" "\$TMP_IPS"
    exit 1
fi

# Генерируем конфиг для fw4 (nftables)
cat << NFT_EOF > "\$TMP_NFT"
set vpn_domains {
    type ipv4_addr
    flags interval
    auto-merge
    elements = { \$SORTED_IPS }
}

chain mangle_prerouting_awg {
    type filter hook prerouting priority mangle; policy accept;
    iifname "br-lan" ip daddr @vpn_domains meta mark set 0x1
}
NFT_EOF

# Перезапускаем фаервол только если список IP/подсетей изменился
if ! cmp -s "\$TMP_NFT" "\$FINAL_NFT"; then
    mv "\$TMP_NFT" "\$FINAL_NFT"
    /etc/init.d/firewall restart >/dev/null 2>&1
    logger -t awg-updater "Списки успешно обновлены, фаервол перезапущен"
else
    rm -f "\$TMP_NFT"
    logger -t awg-updater "Изменений в списках нет"
fi

rm -f "\$TMP_RAW" "\$TMP_IPS"
EOF

chmod +x "$UPDATE_SCRIPT"

echo "3. Добавление задачи в cron (ежедневно в 04:00)..."
mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i "\|$UPDATE_SCRIPT|d" /etc/crontabs/root
echo "0 4 * * * $UPDATE_SCRIPT" >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart

echo "4. Применение сетевых настроек и первичная загрузка списка (займёт ~20-30 секунд)..."
/etc/init.d/network restart
"$UPDATE_SCRIPT"

echo "Установка завершена!"