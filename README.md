# SSTP VPN Server

SSTP (Secure Socket Tunneling Protocol) VPN-сервер на базе SoftEther.

## Быстрый старт

```bash
# Установка (от root)
sudo bash setup-sstp.sh install

# Добавить пользователя
sudo bash setup-sstp.sh add-user myuser mypassword

# Статус
sudo bash setup-sstp.sh status

# Удаление
sudo bash setup-sstp.sh uninstall
```

## Требования

- Ubuntu 20.04+ / Debian 11+
- Root доступ
- Открытый порт 443 (TCP)

## Структура

```
.
├── setup-sstp.sh           # Основной скрипт установки
├── config/
│   ├── server.conf         # Конфигурация сервера
│   └── firewall-rules.sh   # Правила iptables
└── README.md
```

## Подключение клиента

### Windows
1. Параметры → Сеть → VPN → Добавить VPN-подключение
2. Поставщик: Windows (встроенный)
3. Тип: SSTP
4. Адрес: IP вашего сервера
5. Логин/пароль: из `setup-sstp.sh add-user`

### Linux
```bash
sudo apt install sstp-client ppp
sudo sstpc --server <IP>:443 --user <user> --password <pass> \
    --ca-cert /path/to/server.crt usepeerdns require-mschap-v2 noauth
```

### macOS
Используйте SoftEther VPN Client или iSSTP из App Store.

## Конфигурация

Основные параметры в `config/server.conf`:
- `VPN_PORT` — порт сервера (по умолчанию 443)
- `VPN_SUBNET` — подсеть для клиентов
- `DNS_PRIMARY` / `DNS_SECONDARY` — DNS серверы
- `MAX_CONNECTIONS` — макс. подключений

## SSL-сертификат

По умолчанию создаётся самоподписанный сертификат. Для продакшена:

```bash
# Let's Encrypt
apt install certbot
certbot certonly --standalone -d vpn.example.com

# Указать в server.conf:
# SSL_CERT_PATH=/etc/letsencrypt/live/vpn.example.com/fullchain.pem
# SSL_KEY_PATH=/etc/letsencrypt/live/vpn.example.com/privkey.pem
```

## Управление

```bash
systemctl start sstp-vpn    # Запуск
systemctl stop sstp-vpn     # Остановка
systemctl restart sstp-vpn  # Перезапуск
systemctl status sstp-vpn   # Статус
journalctl -u sstp-vpn -f   # Логи
```
