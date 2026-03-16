#!/bin/bash
#
# Правила файрвола для SSTP VPN сервера
# Запускать от root: sudo bash firewall-rules.sh
#
set -euo pipefail

VPN_PORT=443
VPN_SUBNET="10.10.0.0/24"
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)

echo "Настройка файрвола для SSTP VPN..."
echo "Интерфейс: $IFACE"

# Разрешить входящий SSTP (TCP 443)
iptables -A INPUT -p tcp --dport "$VPN_PORT" -j ACCEPT

# NAT для VPN-клиентов
iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$IFACE" -j MASQUERADE

# Пересылка трафика VPN-клиентов
iptables -A FORWARD -s "$VPN_SUBNET" -j ACCEPT
iptables -A FORWARD -d "$VPN_SUBNET" -j ACCEPT

# Разрешить established/related
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Сохранение
if command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo "Правила сохранены в /etc/iptables/rules.v4"
fi

echo "Файрвол настроен."
