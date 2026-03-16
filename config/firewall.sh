#!/bin/bash
#
# Правила файрвола для ANet VPN сервера
# Запуск: sudo bash firewall.sh
#
set -euo pipefail

SERVER_PORT=443
TUN_IFACE="tun0"
EXT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)

echo "Настройка файрвола для ANet..."
echo "Внешний интерфейс: $EXT_IFACE"
echo "VPN интерфейс: $TUN_IFACE"
echo "Порт: $SERVER_PORT/UDP"

# IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-anet.conf

# Разрешить входящий UDP на порт сервера
iptables -I INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT

# Пересылка трафика между интерфейсами
iptables -I FORWARD -i "$EXT_IFACE" -o "$TUN_IFACE" -j ACCEPT
iptables -I FORWARD -i "$TUN_IFACE" -o "$EXT_IFACE" -j ACCEPT

# NAT
iptables -t nat -A POSTROUTING -o "$EXT_IFACE" -j MASQUERADE

# Проверка
iptables -L -v -n

# Сохранение
if command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "Правила сохранены."
fi

echo "Готово."
