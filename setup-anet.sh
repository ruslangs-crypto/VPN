#!/bin/bash
#
# ANet VPN Server Setup Script
# Устанавливает и настраивает ANet VPN сервер (ASTP протокол)
# Проект: https://github.com/ZeroTworu/anet
#
set -euo pipefail

ANET_VERSION="0.5.1"
INSTALL_DIR="/opt/anet"
CONFIG_DIR="/etc/anet"
ANET_USER="anet"
SERVER_PORT=443

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

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)
            log_error "Архитектура $arch не поддерживается. ANet поддерживает amd64 и arm64."
            exit 1
            ;;
    esac
}

# --- Скачивание бинарников ---
download_anet() {
    local arch
    arch=$(detect_arch)

    log_info "Скачивание ANet v${ANET_VERSION} (${arch})..."

    mkdir -p "$INSTALL_DIR"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Скачиваем сервер
    local server_url="https://github.com/ZeroTworu/anet/releases/download/v${ANET_VERSION}/server_${ANET_VERSION}.zip"
    log_info "Загрузка сервера: $server_url"
    wget -q "$server_url" -O "$tmp_dir/server.zip" || {
        log_error "Не удалось скачать сервер. Проверьте сеть и версию."
        exit 1
    }

    # Скачиваем клиент (для генерации ключей / тестов)
    local client_url="https://github.com/ZeroTworu/anet/releases/download/v${ANET_VERSION}/client-linux-${arch}_${ANET_VERSION}.zip"
    log_info "Загрузка клиента: $client_url"
    wget -q "$client_url" -O "$tmp_dir/client.zip" || {
        log_warn "Не удалось скачать клиент. Продолжаем без него."
    }

    # Распаковка
    cd "$tmp_dir"
    apt-get install -y -qq unzip 2>/dev/null || true

    unzip -o server.zip -d "$INSTALL_DIR/"
    if [[ -f client.zip ]]; then
        unzip -o client.zip -d "$INSTALL_DIR/"
    fi

    chmod +x "$INSTALL_DIR"/anet-*

    rm -rf "$tmp_dir"
    log_info "ANet установлен в $INSTALL_DIR"
    ls -la "$INSTALL_DIR"/anet-* 2>/dev/null || true
}

# --- Генерация ключей ---
generate_keys() {
    log_info "Генерация ключей сервера..."

    mkdir -p "$CONFIG_DIR/keys"

    if [[ -x "$INSTALL_DIR/anet-keygen" ]]; then
        cd "$CONFIG_DIR/keys"
        "$INSTALL_DIR/anet-keygen" server > server_keys.txt 2>&1 || true
        "$INSTALL_DIR/anet-keygen" client > client_keys.txt 2>&1 || true
        cd /
        log_info "Ключи сгенерированы в $CONFIG_DIR/keys/"
    else
        log_warn "anet-keygen не найден. Сгенерируйте ключи вручную:"
        log_warn "  $INSTALL_DIR/anet-keygen server"
        log_warn "  $INSTALL_DIR/anet-keygen client"
    fi
}

# --- Генерация TLS-сертификата для QUIC ---
generate_tls_cert() {
    log_info "Генерация TLS-сертификата для QUIC транспорта..."

    mkdir -p "$CONFIG_DIR/certs"

    openssl req -x509 -newkey ed25519 \
        -keyout "$CONFIG_DIR/certs/key.pem" \
        -out "$CONFIG_DIR/certs/cert.pem" \
        -days 365 -nodes \
        -subj "/CN=anet" \
        -addext "subjectAltName = DNS:anet" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=digitalSignature,keyEncipherment" \
        2>/dev/null

    chmod 600 "$CONFIG_DIR/certs/key.pem"
    chmod 644 "$CONFIG_DIR/certs/cert.pem"

    log_info "TLS-сертификат создан в $CONFIG_DIR/certs/"
}

# --- Создание конфига сервера ---
create_server_config() {
    log_info "Создание конфигурации сервера..."

    mkdir -p "$CONFIG_DIR"

    # Читаем сгенерированные ключи если есть
    local server_private_key="<ВСТАВЬТЕ_ПРИВАТНЫЙ_КЛЮЧ_СЕРВЕРА>"
    local server_public_key="<ВСТАВЬТЕ_ПУБЛИЧНЫЙ_КЛЮЧ_СЕРВЕРА>"

    if [[ -f "$CONFIG_DIR/keys/server_keys.txt" ]]; then
        log_info "Ключи найдены — вставьте их в конфиг вручную."
        log_info "Содержимое:"
        cat "$CONFIG_DIR/keys/server_keys.txt"
    fi

    # Читаем TLS-сертификат
    local cert_content=""
    local key_content=""
    if [[ -f "$CONFIG_DIR/certs/cert.pem" ]]; then
        cert_content=$(cat "$CONFIG_DIR/certs/cert.pem")
        key_content=$(cat "$CONFIG_DIR/certs/key.pem")
    fi

    cp /home/user/VPN/config/server.toml "$CONFIG_DIR/server.toml" 2>/dev/null || {
        log_info "Шаблон конфига скопирован. Отредактируйте $CONFIG_DIR/server.toml"
    }

    log_info "Конфигурация: $CONFIG_DIR/server.toml"
    log_warn "Не забудьте вставить ключи и fingerprint-ы клиентов в конфиг!"
}

# --- Настройка сети (iptables + forwarding) ---
configure_network() {
    log_info "Настройка сетевых параметров..."

    # IP forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-anet.conf
    sysctl --system >/dev/null 2>&1

    # Определение основного интерфейса
    local iface
    iface=$(ip route show default | awk '/default/ {print $5}' | head -1)

    if [[ -z "$iface" ]]; then
        log_warn "Не удалось определить сетевой интерфейс. Настройте iptables вручную."
        return
    fi

    local tun_iface="tun0"

    # Разрешить входящий UDP на порт сервера
    iptables -C INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT

    # Пересылка между интерфейсами
    iptables -C FORWARD -i "$iface" -o "$tun_iface" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "$iface" -o "$tun_iface" -j ACCEPT

    iptables -C FORWARD -i "$tun_iface" -o "$iface" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "$tun_iface" -o "$iface" -j ACCEPT

    # NAT
    iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

    # Сохранение
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi

    log_info "Сеть настроена: UDP/$SERVER_PORT открыт, NAT через $iface, forwarding $iface <-> $tun_iface"
}

# --- Systemd сервис ---
create_systemd_service() {
    log_info "Создание systemd сервиса..."

    cat > /etc/systemd/system/anet-server.service <<EOF
[Unit]
Description=ANet VPN Server (ASTP Protocol)
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/anet-server -c ${CONFIG_DIR}/server.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable anet-server.service
    log_info "Systemd сервис anet-server создан и включен."
}

# --- Вывод информации ---
print_summary() {
    local server_ip
    server_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    echo "============================================="
    echo "  ANet VPN Server (ASTP) — Setup Complete"
    echo "============================================="
    echo ""
    echo "  Версия:       v${ANET_VERSION}"
    echo "  Сервер:       ${server_ip}"
    echo "  Порт:         ${SERVER_PORT}/UDP (ASTP)"
    echo "  Бинарники:    ${INSTALL_DIR}/"
    echo "  Конфиг:       ${CONFIG_DIR}/server.toml"
    echo "  Ключи:        ${CONFIG_DIR}/keys/"
    echo "  TLS серт.:    ${CONFIG_DIR}/certs/"
    echo ""
    echo "  Следующие шаги:"
    echo "    1. Отредактируйте ${CONFIG_DIR}/server.toml"
    echo "       — вставьте приватный ключ сервера"
    echo "       — добавьте fingerprint-ы клиентов"
    echo "    2. Запустите: systemctl start anet-server"
    echo "    3. Проверьте: systemctl status anet-server"
    echo ""
    echo "  Добавить клиента:"
    echo "    ${INSTALL_DIR}/anet-keygen client"
    echo "    # Добавьте fingerprint в allowed_clients в server.toml"
    echo ""
    echo "  Управление:"
    echo "    systemctl start anet-server"
    echo "    systemctl stop anet-server"
    echo "    systemctl status anet-server"
    echo "    journalctl -u anet-server -f"
    echo ""
    echo "============================================="
}

# --- Главная ---
main() {
    case "${1:-install}" in
        install)
            log_info "=== Установка ANet VPN сервера (ASTP) ==="
            download_anet
            generate_keys
            generate_tls_cert
            create_server_config
            configure_network
            create_systemd_service
            print_summary
            ;;
        keys)
            generate_keys
            ;;
        network)
            configure_network
            ;;
        status)
            systemctl status anet-server
            ;;
        uninstall)
            log_warn "Удаление ANet VPN сервера..."
            systemctl stop anet-server 2>/dev/null || true
            systemctl disable anet-server 2>/dev/null || true
            rm -f /etc/systemd/system/anet-server.service
            systemctl daemon-reload
            rm -rf "$INSTALL_DIR"
            rm -rf "$CONFIG_DIR"
            rm -f /etc/sysctl.d/99-anet.conf
            log_info "ANet VPN сервер удалён."
            ;;
        *)
            echo "Использование: $0 {install|keys|network|status|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
