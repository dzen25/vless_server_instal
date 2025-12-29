#!/bin/bash

# === Конфигурационные параметры ===
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CLIENT_CONFIG_DIR="/etc/xray/client_configs"
XRAY_CERT_DIR="/etc/xray/cert"
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
        echo "❌ Домен '$DOMAIN' не резолвится. Проверьте DNS-записы."
        exit 1
    fi
}

# === Создание директорий ===
create_directories() {
    echo "📁 Создание директорий..."
    mkdir -p "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$XRAY_CERT_DIR" "/var/log/xray"
    
    # Лог-файлы создаем но не используем (логи отключены в конфиге)
    touch /var/log/xray/{access.log,error.log}
    chown -R nobody:nogroup /var/log/xray
    chmod -R 755 /var/log/xray
    
    # Права на директорию сертификатов
    chown -R nobody:nogroup "$XRAY_CERT_DIR"
    chmod 755 "$XRAY_CERT_DIR"
}

# === Установка зависимостей ===
install_dependencies() {
    echo "📦 Установка зависимостей..."
    apt update > /dev/null
    apt install -y curl qrencode ufw cron certbot jq > /dev/null
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

    # Освобождаем порт 80 если он занят Xray
    systemctl stop xray 2>/dev/null || true

    # Получаем сертификат через certbot
    if ! certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" \
        --agree-tos --non-interactive --key-type ecdsa --force-renewal; then
        echo "❌ Ошибка получения сертификата"
        exit 1
    fi

    # КОПИРУЕМ сертификаты в директорию Xray (не симлинки!)
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$XRAY_CERT_DIR/fullchain.cer"
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$XRAY_CERT_DIR/private.key"
    
    # Устанавливаем правильные права для пользователя nobody
    chown nobody:nogroup "$XRAY_CERT_DIR"/*
    chmod 644 "$XRAY_CERT_DIR/fullchain.cer"
    chmod 600 "$XRAY_CERT_DIR/private.key"

    # Добавляем обновление сертификатов в cron с КОПИРОВАНИЕМ
    (crontab -l 2>/dev/null | grep -v "certbot renew.*$DOMAIN"; \
     echo "0 3 * * * certbot renew --quiet --cert-name $DOMAIN --post-hook \"cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $XRAY_CERT_DIR/fullchain.cer && cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $XRAY_CERT_DIR/private.key && chown nobody:nogroup $XRAY_CERT_DIR/* && chmod 644 $XRAY_CERT_DIR/fullchain.cer && chmod 600 $XRAY_CERT_DIR/private.key && systemctl restart xray\"") | crontab -
}

# === Настройка фаервола ===
setup_firewall() {
    echo "🛡 Настройка UFW..."
    ufw allow 443/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw --force enable > /dev/null
}

# === Генерация UUID и серверного конфигурационного файла ===
generate_server_config() {
    echo "🧩 Генерация конфигурации Xray..."
    local config_file="$XRAY_CONFIG_DIR/config.json"
    
    # Инициализация массива для клиентов
    local client_entries=()
    
    # Генерация уникальных UUID для каждого устройства
    for i in $(seq 1 "$NUM_DEVICES"); do
        local uuid=$(xray uuid)
        UUIDs[$i]="$uuid"
        
        # Создание JSON-объекта для клиента
        client_entries+=("{
          \"id\": \"$uuid\",
          \"flow\": \"xtls-rprx-vision\",
          \"email\": \"device-$i\"
        }")
    done
    
    # Объединение клиентов через запятую
    local clients=$(IFS=,; echo "${client_entries[*]}")
    
    # Генерация конфигурационного файла с правильными путями к сертификатам
    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [$clients],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "$XRAY_CERT_DIR/fullchain.cer",
          "keyFile": "$XRAY_CERT_DIR/private.key"
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

    # Проверяем конфиг перед запуском
    if ! /usr/local/bin/xray run -test -config "$config_file"; then
        echo "❌ Ошибка в конфигурации Xray"
        exit 1
    fi
    
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
          "id": "${UUIDs[$i]}",
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
DOMAIN=$(grep DOMAIN /etc/xray/.installed 2>/dev/null | cut -d= -f2)
if [ -z "$DOMAIN" ]; then
    echo "❌ Xray не установлен через этот скрипт"
    exit 1
fi

FLOW="xtls-rprx-vision"
FINGERPRINT="chrome"
PORT=443

mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sort)

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
if [ -z "$UUID" ]; then
    echo "❌ Не удалось извлечь UUID из конфига"
    exit 1
fi

VLESS_URL="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=tls&type=tcp&fp=${FINGERPRINT}#${selected##*/}"

echo -e "\n=== Конфигурация клиента ==="
echo "Домен: $DOMAIN"
echo "Порт: $PORT"
echo "UUID: $UUID"
echo "Протокол: VLESS + XTLS Vision"
echo -e "\nСсылка для импорта:"
echo "$VLESS_URL"
echo -e "\nQR-код:"
qrencode -t UTF8 "$VLESS_URL" 2>/dev/null || echo "Установите qrencode для отображения QR-кода"
EOF

    chmod +x "$GENERATE_SCRIPT"
}

# === Показать информацию о сервере ===
show_server_info() {
    if [ ! -f "$MARKER_FILE" ]; then
        echo "❌ Xray не установлен"
        return 1
    fi
    
    . "$MARKER_FILE"
    echo -e "\n=== Информация о сервере ==="
    echo "Домен: $DOMAIN"
    echo "Устройств: $NUM_DEVICES"
    echo "Email: $EMAIL"
    
    # Статус Xray
    echo -e "\nСтатус Xray:"
    systemctl status xray --no-pager | grep -E "(Active:|Main PID:|CPU:)" | head -3
    
    # Статус сертификата
    if [ -f "$XRAY_CERT_DIR/fullchain.cer" ]; then
        echo -e "\nСертификат:"
        openssl x509 -in "$XRAY_CERT_DIR/fullchain.cer" -noout -subject -dates 2>/dev/null | \
            sed 's/subject=//; s/notBefore=//; s/notAfter=//' | \
            while read line; do echo "  $line"; done
    fi
    
    # Клиентские конфиги
    local config_count=$(find "$CLIENT_CONFIG_DIR" -name "*.json" 2>/dev/null | wc -l)
    echo -e "\nКлиентских конфигов: $config_count"
}

# === Удаление всего ===
uninstall_all() {
    echo -e "\n🧹 Удаление Xray и конфигураций..."
    read -p "Вы уверены? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Отменено"
        return
    fi
    
    systemctl stop xray 2>/dev/null || true
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    
    # Удаляем только наши файлы, оставляя Let's Encrypt сертификаты
    rm -rf "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$XRAY_CERT_DIR" "$GENERATE_SCRIPT"
    rm -f /var/log/xray/{access.log,error.log} 2>/dev/null
    
    # Удаляем только нашу запись из cron
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "certbot renew.*$DOMAIN" > "$temp_cron" 2>/dev/null
    crontab "$temp_cron" 2>/dev/null
    rm -f "$temp_cron"
    
    # Отключаем порты в UFW если они были открыты только для Xray
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow 80/tcp 2>/dev/null || true
    
    rm -f "$MARKER_FILE"
    echo "✅ Xray удален"
    echo "ℹ️  Сертификаты Let's Encrypt сохранены в /etc/letsencrypt/"
}

# === Главное меню ===
main_menu() {
    while true; do
        echo -e "\n==== XRAY МЕНЮ ===="
        echo "1. Показать информацию о сервере"
        echo "2. Сгенерировать ссылку/QR-код"
        echo "3. Перезапустить Xray"
        echo "4. Проверить статус сертификата"
        echo "5. Удалить Xray"
        echo "6. Выйти"
        echo "===================="
        read -p "Выберите действие (1-6): " choice
        
        case $choice in
            1)
                show_server_info
                ;;
            2)
                if [ -x "$GENERATE_SCRIPT" ]; then
                    "$GENERATE_SCRIPT"
                else
                    echo "❌ Скрипт генерации не найден"
                fi
                ;;
            3)
                echo "🔄 Перезапуск Xray..."
                systemctl restart xray
                systemctl status xray --no-pager | head -5
                ;;
            4)
                if [ -f "$XRAY_CERT_DIR/fullchain.cer" ]; then
                    echo "📅 Проверка сертификата:"
                    openssl x509 -in "$XRAY_CERT_DIR/fullchain.cer" -noout -enddate 2>/dev/null | \
                        cut -d= -f2 | xargs -I {} date -d {} +"%d.%m.%Y %H:%M:%S"
                    echo "Дней осталось: $(( ($(date -d "$(openssl x509 -in "$XRAY_CERT_DIR/fullchain.cer" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))"
                else
                    echo "❌ Сертификат не найден"
                fi
                ;;
            5)
                uninstall_all
                # Если удалили, выходим из меню
                [ ! -f "$MARKER_FILE" ] && exit 0
                ;;
            6)
                echo "Выход..."
                exit 0
                ;;
            *)
                echo "Неверный выбор"
                ;;
        esac
        
        echo -e "\nНажмите Enter для продолжения..."
        read
    done
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
    # Если уже установлен - показываем меню
    if [ -f "$MARKER_FILE" ]; then
        echo "✅ Xray уже установлен"
        main_menu
        exit 0
    fi
    
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

# Объявление массива для хранения UUID
declare -A UUIDs

generate_server_config
generate_client_configs
install_generate_script

# Сохраняем данные установки
echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL\nNUM_DEVICES=$NUM_DEVICES" > "$MARKER_FILE"

echo -e "\n✅ Установка завершена!"
echo "========================================"
show_server_info
echo -e "\nИспользуйте:"
echo "  • $0 - для доступа к меню"
echo "  • generate_client_config - для генерации ссылок"
echo "========================================"

# Предлагаем показать первую ссылку
read -p "Сгенерировать первую ссылку сейчас? (y/N): " generate_now
if [[ "$generate_now" =~ ^[Yy]$ ]]; then
    if [ -x "$GENERATE_SCRIPT" ]; then
        "$GENERATE_SCRIPT"
    fi
fi
