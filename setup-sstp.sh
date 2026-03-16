#!/bin/bash
#
# SSTP VPN Server Setup Script
# Устанавливает и настраивает SSTP VPN сервер на Linux (Ubuntu/Debian)
# Использует SoftEther VPN Server для поддержки SSTP
#
set -euo pipefail

# --- Конфигурация ---
SOFTETHER_VERSION="v4.43-9799-beta"
SOFTETHER_BUILD="2023.08.31"
INSTALL_DIR="/opt/softether"
VPN_PORT=443
VPN_SUBNET="10.10.0.0"
VPN_SUBNET_MASK="255.255.255.0"
VPN_GATEWAY="10.10.0.1"
DHCP_START="10.10.0.10"
DHCP_END="10.10.0.200"
DNS_SERVER="8.8.8.8"
HUB_NAME="VPN"
CONFIG_DIR="/etc/sstp-vpn"

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Проверки ---
if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен быть запущен от root (sudo)"
    exit 1
fi

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        log_error "Не удалось определить ОС. Поддерживаются Ubuntu/Debian."
        exit 1
    fi
}

# --- Установка зависимостей ---
install_dependencies() {
    log_info "Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq \
        build-essential \
        libssl-dev \
        libreadline-dev \
        zlib1g-dev \
        wget \
        curl \
        iptables \
        net-tools \
        openssl \
        ca-certificates
    log_info "Зависимости установлены."
}

# --- Скачивание и сборка SoftEther ---
install_softether() {
    log_info "Скачивание SoftEther VPN Server..."

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64bit" ;;
        aarch64) arch="64bit" ;;
        *)
            log_error "Архитектура $arch не поддерживается."
            exit 1
            ;;
    esac

    local url="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/${SOFTETHER_VERSION}/softether-vpnserver-${SOFTETHER_VERSION}-${SOFTETHER_BUILD}-linux-x64-${arch}.tar.gz"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    wget -q "$url" -O softether.tar.gz || {
        log_warn "Не удалось скачать конкретную версию, пробуем клонировать из исходников..."
        apt-get install -y -qq git cmake
        git clone --depth 1 https://github.com/SoftEtherVPN/SoftEtherVPN_Stable.git softether-src
        cd softether-src
        if [[ -f configure ]]; then
            ./configure
            make -j"$(nproc)"
        elif [[ -f CMakeLists.txt ]]; then
            mkdir build && cd build
            cmake ..
            make -j"$(nproc)"
        fi
        cd "$tmp_dir"
    }

    if [[ -f softether.tar.gz ]]; then
        tar xzf softether.tar.gz
        cd vpnserver
        yes 1 | make
    fi

    mkdir -p "$INSTALL_DIR"
    cp -r . "$INSTALL_DIR/vpnserver" 2>/dev/null || true

    chmod 600 "$INSTALL_DIR/vpnserver/"*
    chmod 700 "$INSTALL_DIR/vpnserver/vpnserver"
    chmod 700 "$INSTALL_DIR/vpnserver/vpncmd"

    rm -rf "$tmp_dir"
    log_info "SoftEther VPN Server установлен в $INSTALL_DIR"
}

# --- Systemd сервис ---
create_systemd_service() {
    log_info "Создание systemd сервиса..."

    cat > /etc/systemd/system/sstp-vpn.service <<EOF
[Unit]
Description=SoftEther VPN Server (SSTP)
After=network.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=${INSTALL_DIR}/vpnserver/vpnserver start
ExecStop=${INSTALL_DIR}/vpnserver/vpnserver stop
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sstp-vpn.service
    log_info "Systemd сервис создан и включен."
}

# --- Генерация SSL сертификата ---
generate_ssl_cert() {
    log_info "Генерация SSL-сертификата..."

    mkdir -p "$CONFIG_DIR/certs"

    local server_ip
    server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=VPN/CN=${server_ip}" \
        -keyout "$CONFIG_DIR/certs/server.key" \
        -out "$CONFIG_DIR/certs/server.crt" \
        2>/dev/null

    chmod 600 "$CONFIG_DIR/certs/server.key"
    chmod 644 "$CONFIG_DIR/certs/server.crt"

    log_info "SSL-сертификат создан: $CONFIG_DIR/certs/"
    log_warn "Для продакшена рекомендуется использовать сертификат от Let's Encrypt или другого CA."
}

# --- Настройка IP forwarding и NAT ---
configure_network() {
    log_info "Настройка сетевых параметров..."

    # IP forwarding
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Определение основного интерфейса
    local iface
    iface=$(ip route show default | awk '/default/ {print $5}' | head -1)

    if [[ -z "$iface" ]]; then
        log_warn "Не удалось определить интерфейс. Настройте NAT вручную."
        return
    fi

    # NAT правила
    iptables -t nat -C POSTROUTING -s "$VPN_SUBNET/24" -o "$iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$VPN_SUBNET/24" -o "$iface" -j MASQUERADE

    iptables -C FORWARD -s "$VPN_SUBNET/24" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -s "$VPN_SUBNET/24" -j ACCEPT

    iptables -C FORWARD -d "$VPN_SUBNET/24" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -d "$VPN_SUBNET/24" -j ACCEPT

    # Сохранение правил
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi

    log_info "IP forwarding включен, NAT настроен через $iface."
}

# --- Настройка VPN сервера ---
configure_vpn_server() {
    log_info "Запуск и настройка VPN сервера..."

    # Запуск сервера
    "${INSTALL_DIR}/vpnserver/vpnserver" start

    sleep 3

    local vpncmd="${INSTALL_DIR}/vpnserver/vpncmd"

    # Генерация случайного пароля администратора
    local admin_pass
    admin_pass=$(openssl rand -base64 24)

    # Настройка через vpncmd
    "$vpncmd" localhost /SERVER /CMD ServerPasswordSet "$admin_pass"

    # Создание Hub
    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /CMD HubCreate "$HUB_NAME" /PASSWORD:""

    # Включение SecureNAT с DHCP
    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /HUB:"$HUB_NAME" /CMD SecureNatEnable
    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /HUB:"$HUB_NAME" /CMD DhcpSet \
        /START:"$DHCP_START" /END:"$DHCP_END" /MASK:"$VPN_SUBNET_MASK" \
        /EXPIRE:7200 /GW:"$VPN_GATEWAY" /DNS:"$DNS_SERVER" /DNS2:8.8.4.4 \
        /DOMAIN:none /LOG:yes /PUSHROUTE:none

    # Установка SSL сертификата
    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /CMD ServerCertSet \
        /LOADCERT:"$CONFIG_DIR/certs/server.crt" /LOADKEY:"$CONFIG_DIR/certs/server.key"

    # Включение SSTP
    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /CMD SstpEnable yes

    # Остановка (будет запущен через systemd)
    "${INSTALL_DIR}/vpnserver/vpnserver" stop

    # Сохранение пароля администратора
    mkdir -p "$CONFIG_DIR"
    echo "$admin_pass" > "$CONFIG_DIR/admin_password"
    chmod 600 "$CONFIG_DIR/admin_password"

    log_info "VPN сервер настроен."
    log_info "Пароль администратора сохранен в $CONFIG_DIR/admin_password"
}

# --- Создание VPN пользователя ---
create_vpn_user() {
    local username="${1:-vpnuser}"
    local password="${2:-}"

    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 16)
    fi

    local admin_pass
    admin_pass=$(cat "$CONFIG_DIR/admin_password")
    local vpncmd="${INSTALL_DIR}/vpnserver/vpncmd"

    # Запускаем сервер если не запущен
    "${INSTALL_DIR}/vpnserver/vpnserver" start 2>/dev/null || true
    sleep 2

    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /HUB:"$HUB_NAME" /CMD UserCreate "$username" /GROUP:none /REALNAME:none /NOTE:none
    "$vpncmd" localhost /SERVER /PASSWORD:"$admin_pass" /HUB:"$HUB_NAME" /CMD UserPasswordSet "$username" /PASSWORD:"$password"

    log_info "Пользователь создан:"
    echo "  Имя: $username"
    echo "  Пароль: $password"

    # Сохраняем данные пользователя
    echo "${username}:${password}" >> "$CONFIG_DIR/users.txt"
    chmod 600 "$CONFIG_DIR/users.txt"
}

# --- Вывод информации ---
print_summary() {
    local server_ip
    server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local admin_pass
    admin_pass=$(cat "$CONFIG_DIR/admin_password" 2>/dev/null || echo "N/A")

    echo ""
    echo "============================================="
    echo "  SSTP VPN Server Setup Complete"
    echo "============================================="
    echo ""
    echo "  Сервер:       $server_ip"
    echo "  Порт:         $VPN_PORT (SSTP/HTTPS)"
    echo "  Hub:          $HUB_NAME"
    echo "  Подсеть:      $VPN_SUBNET/24"
    echo "  DNS:          $DNS_SERVER"
    echo ""
    echo "  Admin пароль: $CONFIG_DIR/admin_password"
    echo "  Пользователи: $CONFIG_DIR/users.txt"
    echo "  Сертификат:   $CONFIG_DIR/certs/server.crt"
    echo ""
    echo "  Управление:"
    echo "    systemctl start sstp-vpn"
    echo "    systemctl stop sstp-vpn"
    echo "    systemctl status sstp-vpn"
    echo ""
    echo "  Добавить пользователя:"
    echo "    $0 add-user <username> [password]"
    echo ""
    echo "============================================="
}

# --- Главная ---
main() {
    case "${1:-install}" in
        install)
            log_info "=== Установка SSTP VPN сервера ==="
            detect_os
            install_dependencies
            install_softether
            generate_ssl_cert
            configure_vpn_server
            create_vpn_user "vpnuser"
            configure_network
            create_systemd_service
            systemctl start sstp-vpn
            print_summary
            ;;
        add-user)
            create_vpn_user "${2:-}" "${3:-}"
            ;;
        status)
            systemctl status sstp-vpn
            ;;
        uninstall)
            log_warn "Удаление SSTP VPN сервера..."
            systemctl stop sstp-vpn 2>/dev/null || true
            systemctl disable sstp-vpn 2>/dev/null || true
            rm -f /etc/systemd/system/sstp-vpn.service
            systemctl daemon-reload
            rm -rf "$INSTALL_DIR"
            rm -rf "$CONFIG_DIR"
            log_info "VPN сервер удалён."
            ;;
        *)
            echo "Использование: $0 {install|add-user|status|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
