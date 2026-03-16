# ANet VPN Server (ASTP Protocol)

Скрипты для развёртывания [ANet](https://github.com/ZeroTworu/anet) VPN-сервера с протоколом ASTP.

**ASTP** (ANet Secure Transport Protocol) — собственный транспортный протокол ANet:
- ChaCha20/Poly1305 + X25519 + Ed25519
- Четырёхфазный хэндшейк (DH + double ratchet)
- Трафик неотличим от случайного UDP (каждый пакет начинается с 12-байтного nonce)
- Устойчив к высокой потере пакетов

## Быстрый старт

```bash
# 1. Установка (от root)
sudo bash setup-anet.sh install

# 2. Сгенерировать ключи сервера
/opt/anet/anet-keygen server

# 3. Сгенерировать ключи клиента
/opt/anet/anet-keygen client

# 4. Вставить ключи и TLS-сертификат в конфиг
sudo nano /etc/anet/server.toml

# 5. Добавить fingerprint клиента в allowed_clients

# 6. Запустить
sudo systemctl start anet-server
sudo systemctl status anet-server
```

## Структура

```
.
├── setup-anet.sh              # Скрипт установки сервера
├── config/
│   ├── server.toml            # Шаблон конфига сервера
│   ├── client.toml            # Шаблон конфига клиента
│   ├── firewall.sh            # Правила iptables
│   ├── docker-compose.yml     # PostgreSQL для anet-auth
│   └── .env.example           # Переменные окружения для БД
└── README.md
```

## Требования

- Linux (Ubuntu 20.04+ / Debian 11+)
- Root доступ
- Открытый порт 443/UDP

## Настройка сервера

### 1. Генерация ключей

```bash
# Ключи сервера
/opt/anet/anet-keygen server
# Выведет: private_key, public_key

# Ключи клиента
/opt/anet/anet-keygen client
# Выведет: private_key, public_key, fingerprint
```

### 2. TLS-сертификат (для QUIC)

```bash
openssl req -x509 -newkey ed25519 \
    -keyout key.pem -out cert.pem \
    -days 365 -nodes -subj "/CN=anet" \
    -addext "subjectAltName = DNS:anet" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyEncipherment"
```

### 3. Конфигурация server.toml

Вставьте в `/etc/anet/server.toml`:
- Приватный/публичный ключ сервера в `[keys]`
- Содержимое cert.pem и key.pem в `[tls]`
- Fingerprint клиентов в `allowed_clients`

### 4. Файрвол

```bash
sudo bash config/firewall.sh
```

## Подключение клиента

### Linux
```bash
# Скачать клиент
wget https://github.com/ZeroTworu/anet/releases/download/v0.5.1/client-linux-amd64_0.5.1.zip

# Заполнить client.toml
# Запустить (от root)
sudo ./anet-client -c client.toml
```

### Windows
Скачайте установщик: [ANET_VPN_Client_Setup](https://github.com/ZeroTworu/anet/releases)

### Android
APK доступен на [странице релизов](https://github.com/ZeroTworu/anet/releases).

## Режим anet-auth (опционально)

Вместо ручного добавления fingerprint-ов можно использовать сервер авторизации:

```bash
# Поднять PostgreSQL
cd config && docker-compose up -d

# Добавить пользователя
/opt/anet/anet-auth -a username

# В server.toml:
# auth_servers = ["http://127.0.0.1:3000/api/v1"]
```

## Управление

```bash
sudo systemctl start anet-server     # Запуск
sudo systemctl stop anet-server      # Остановка
sudo systemctl restart anet-server   # Перезапуск
sudo systemctl status anet-server    # Статус
sudo journalctl -u anet-server -f    # Логи
```
