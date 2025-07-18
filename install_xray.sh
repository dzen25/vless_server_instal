#!/bin/bash

# === Конфигурационные параметры ===
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CLIENT_CONFIG_DIR="/etc/xray/client_configs"
SSL_DIR="/etc/ssl/vless"
MARKER_FILE="/etc/xray/.installed"
GENERATE_SCRIPT="/usr/local/bin/generate_client_config"
INSTALL_LOG="/var/log/xray/install.log"

# === Проверка прав root ===
if [ "$(id -u)" != "0" ]; then
    echo "Этот скрипт должен запускаться с правами root"
    exit 1
fi

# === Логгирование ===
exec > >(tee -a "$INSTALL_LOG") 2>&1

# === Проверка домена ===
check_domain() {
    if ! getent hosts "$DOMAIN" >/dev/null; then
        echo "❌ Домен '$DOMAIN' не резолвится. Проверьте DNS-записи."
        exit 1
    fi
}

# === Создание директорий ===
create_directories() {
    echo "📁 Создание директорий..."
    mkdir -p "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "/var/log/xray"
    touch /var/log/xray/{access.log,error.log}
    chown -R nobody:nogroup /var/log/xray
    chmod -R 755 /var/log/xray
}

# === Установка зависимостей ===
install_dependencies() {
    echo "📦 Установка зависимостей..."
    apt update > /dev/null
    apt install -y curl qrencode ufw cron certbot > /dev/null
}

# === Установка Xray ===
install_xray() {
    echo "🚀 Установка Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray > /dev/null
}

# === Настройка сертификатов ===
setup_certificates() {
    echo "🔐 Получение TLS-сертификатов для $DOMAIN..."
    certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" \
        --agree-tos --non-interactive --key-type ecdsa || {
        echo "❌ Ошибка получения сертификата"
        exit 1
    }

    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.cer"
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/private.key"

    chown -R nobody:nogroup "$SSL_DIR"
    chmod 600 "$SSL_DIR/private.key"
    chmod 644 "$SSL_DIR/fullchain.cer"

    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook \"systemctl restart xray\"") | crontab -
}

# === Настройка фаервола ===
setup_firewall() {
    echo "🛡 Настройка UFW..."
    ufw allow 443/tcp > /dev/null
    ufw --force enable > /dev/null
}

# === Генерация UUID и серверного конфигурационного файла ===
generate_server_config() {
    echo "🧩 Генерация конфигурации Xray..."
    local config_file="$XRAY_CONFIG_DIR/config.json"
    clients=()

    for i in $(seq 1 "$NUM_DEVICES"); do
        UUIDs[i]=$(xray uuid)
        clients+=("{
            \"id\": \"${UUIDs[i]}\",
            \"flow\": \"xtls-rprx-vision\",
            \"email\": \"device-$i\"
        }")
    done

    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [${clients[*]}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$SSL_DIR/fullchain.cer",
          "keyFile": "$SSL_DIR/private.key"
        }],
        "alpn": ["h2", "http/1.1"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

    systemctl restart xray
}

# === Генерация клиентских конфигов ===
generate_client_configs() {
    echo "📤 Генерация клиентских конфигов..."
    mkdir -p "$CLIENT_CONFIG_DIR"

    for i in $(seq 1 "$NUM_DEVICES"); do
        cat > "$CLIENT_CONFIG_DIR/client_$i.json" <<EOF
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "${UUIDs[i]}",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls"
    }
  }]
}
EOF
    done
}

# === Установка утилиты генерации ссылок ===
install_generate_script() {
    cat > "$GENERATE_SCRIPT" <<'EOF'
#!/bin/bash

CONFIG_DIR="/etc/xray/client_configs"
DOMAIN=$(grep DOMAIN /etc/xray/.installed | cut -d= -f2)
FLOW="xtls-rprx-vision"
PORT=443

mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)

if [ ${#config_files[@]} -eq 0 ]; then
  echo "❌ Конфиги не найдены!"
  exit 1
fi

echo -e "\nДоступные конфиги:"
for i in "${!config_files[@]}"; do
  echo "$((i+1)). ${config_files[$i]##*/}"
done

read -p "Выберите конфиг (1-${#config_files[@]}): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
  echo "Неверный выбор!"
  exit 1
fi

selected="${config_files[$((choice-1))]}"
UUID=$(grep -oP '(?<="id": ")[^"]+' "$selected" | head -1)
VLESS_URL="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=tls&type=tcp#${selected##*/}"

echo -e "\nСсылка:"
echo "$VLESS_URL"
echo -e "\nQR-код:"
qrencode -t UTF8 "$VLESS_URL"
EOF

    chmod +x "$GENERATE_SCRIPT"
}

# === Удаление всего ===
uninstall_all() {
    echo "🧹 Удаление Xray и конфигураций..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    rm -rf "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "$GENERATE_SCRIPT"
    rm -f /var/log/xray/{access.log,error.log}
    crontab -l | grep -v "certbot renew" | crontab -
    ufw delete allow 443/tcp > /dev/null
    ufw --force disable > /dev/null
    rm -f "$MARKER_FILE"
    echo "✅ Удалено"
}

# === Главное меню ===
main_menu() {
    echo -e "\n==== Xray Меню ===="
    echo "1. Показать QR-код"
    echo "2. Удалить Xray"
    echo "3. Выйти"
    read -p "Выбор: " choice
    case $choice in
        1) "$GENERATE_SCRIPT" ;;
        2) uninstall_all ;;
        3) exit 0 ;;
        *) echo "Неверный выбор"; main_menu ;;
    esac
}

# === Обработка флага headless ===
if [ "$1" == "--headless" ]; then
    DOMAIN="$2"
    EMAIL="$3"
    NUM_DEVICES="$4"
    if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$NUM_DEVICES" ]]; then
        echo "Использование: $0 --headless <домен> <email> <кол-во устройств>"
        exit 1
    fi
else
    echo -e "\n=== Установка Xray-сервера ==="
    read -p "Введите домен: " DOMAIN
    read -p "Email для сертификата: " EMAIL
    read -p "Количество устройств: " NUM_DEVICES
fi

# === Проверка предыдущей установки ===
if [ -f "$MARKER_FILE" ]; then
    echo "⚠️ Xray уже установлен"
    main_menu
    exit 0
fi

# === Запуск установки ===
check_domain
create_directories
install_dependencies
install_xray
setup_certificates
setup_firewall

declare -A UUIDs
generate_server_config
generate_client_configs
install_generate_script

echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL\nNUM_DEVICES=$NUM_DEVICES" > "$MARKER_FILE"

echo -e "\n✅ Установка завершена! Используйте 'generate_client_config' для вывода конфигов."

