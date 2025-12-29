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
        echo "❌ Домен '$DOMAIN' не резолвится. Проверьте DNS-записи."
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
    apt install -y curl qrencode ufw cron certbot jq openssl > /dev/null
}

# === Установка Xray ===
install_xray() {
    echo "🚀 Установка Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray > /dev/null
}

setup_certificates() {
    echo "🔐 Проверка TLS-сертификатов для $DOMAIN..."
    
    # Проверяем, есть ли уже сертификат
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo "✅ Сертификат уже существует, используем его"
    else
        echo "🔄 Получение нового сертификата через certbot..."
        
        # Освобождаем порт 80 если он занят Xray
        systemctl stop xray 2>/dev/null || true
        
        # Пробуем получить сертификат БЕЗ --force-renewal
        if ! certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" \
            --agree-tos --non-interactive --key-type ecdsa; then
            echo "⚠️ Не удалось получить новый сертификат"
            echo "   Либо лимит исчерпан, либо другая ошибка"
            echo "   Проверь: sudo certbot certificates"
            return 1  # Не выходим, может есть старый сертификат
        fi
    fi
    
    # КОПИРУЕМ сертификаты в директорию Xray
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$XRAY_CERT_DIR/fullchain.cer"
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$XRAY_CERT_DIR/private.key"
    
    # Устанавливаем правильные права
    chown nobody:nogroup "$XRAY_CERT_DIR"/*
    chmod 644 "$XRAY_CERT_DIR/fullchain.cer"
    chmod 600 "$XRAY_CERT_DIR/private.key"
    
    echo "✅ Сертификаты готовы к использованию"

    # Добавляем обновление сертификатов в cron с КОПИРОВАНИЕМ
    (crontab -l 2>/dev/null | grep -v "certbot renew.*$DOMAIN"; \
     echo "0 3 * * * certbot renew --quiet --cert-name $DOMAIN --post-hook \"cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $XRAY_CERT_DIR/fullchain.cer && cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $XRAY_CERT_DIR/private.key && chown nobody:nogroup $XRAY_CERT_DIR/* && chmod 644 $XRAY_CERT_DIR/fullchain.cer && chmod 600 $XRAY_CERT_DIR/private.key && systemctl restart xray\"") | crontab -
}

# === Настройка фаервола ===
setup_firewall() {
    echo "🛡 Настройка UFW..."
    ufw allow 443/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw allow 22/tcp > /dev/null
    ufw allow 8443/tcp > /dev/null
    ufw --force enable > /dev/null
}

# === Генерация Reality ключей ===
generate_reality_keys() {
    echo "🔑 Генерация Reality ключей..."
    
    # Генерируем ключи X25519
    KEYS_INFO=$(xray x25519)
    REALITY_PRIVATE_KEY=$(echo "$KEYS_INFO" | awk '/Private key:/ {print $3}')
    REALITY_PUBLIC_KEY=$(echo "$KEYS_INFO" | awk '/Public key:/ {print $3}')
    
    # Генерируем short IDs
    SHORT_ID1=$(openssl rand -hex 4)
    SHORT_ID2=$(openssl rand -hex 4)
    
    # Сохраняем ключи в файл для использования в конфиге
    echo "PRIVATE_KEY=$REALITY_PRIVATE_KEY" > /etc/xray/reality_keys
    echo "PUBLIC_KEY=$REALITY_PUBLIC_KEY" >> /etc/xray/reality_keys
    echo "SHORT_ID1=$SHORT_ID1" >> /etc/xray/reality_keys
    echo "SHORT_ID2=$SHORT_ID2" >> /etc/xray/reality_keys
    
    chmod 600 /etc/xray/reality_keys
    
    echo "✅ Reality ключи сгенерированы"
}

generate_server_config() {
    echo "🧩 Генерация конфигурации Xray..."
    local config_file="$XRAY_CONFIG_DIR/config.json"
    
    # Загружаем Reality ключи
    if [ -f /etc/xray/reality_keys ]; then
        . /etc/xray/reality_keys
    else
        echo "❌ Файл с Reality ключами не найден"
        exit 1
    fi
    
    echo "DEBUG: PRIVATE_KEY=$PRIVATE_KEY"
    echo "DEBUG: PUBLIC_KEY=$PUBLIC_KEY"
    echo "DEBUG: SHORT_ID1=$SHORT_ID1"
    echo "DEBUG: SHORT_ID2=$SHORT_ID2"
    
    # Проверяем что ключи не пустые
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "❌ Reality ключи пустые"
        exit 1
    fi
    
    # Генерация конфигурационного файла с ПОДСТАНОВКОЙ переменных
    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$XRAY_CERT_DIR/fullchain.cer",
              "keyFile": "$XRAY_CERT_DIR/private.key"
            }
          ],
          "alpn": ["h2", "http/1.1"]
        }
      }
    },
    {
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.lovelawsblog.com:443",
          "serverNames": [
            "www.lovelawsblog.com",
            "www.google.com"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID1",
            "$SHORT_ID2"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    echo "✅ Конфиг создан. Проверяем содержимое..."
    
    # Проверяем что privateKey записался
    if ! grep -q "\"privateKey\": \"$PRIVATE_KEY\"" "$config_file"; then
        echo "❌ privateKey не записался в конфиг"
        echo "Первые 20 строк конфига:"
        head -20 "$config_file"
        exit 1
    fi
    
    # Проверяем конфиг перед запуском
    echo "Проверка конфига..."
    if ! /usr/local/bin/xray run -test -config "$config_file"; then
        echo "❌ Ошибка в конфигурации Xray"
        echo "Содержимое конфига:"
        cat "$config_file"
        exit 1
    fi
    
    systemctl restart xray
    echo "✅ Серверный конфиг создан"
}

# === Генерация нового клиентского конфига ===
generate_new_client_config() {
    echo -e "\n📱 Генерация нового клиентского конфига"
    
    # Выбор типа конфига
    echo "Выберите тип конфига:"
    echo "1. TLS (порт 443)"
    echo "2. Reality (порт 8443)"
    read -p "Ваш выбор (1-2): " config_type
    
    if [ "$config_type" != "1" ] && [ "$config_type" != "2" ]; then
        echo "❌ Неверный выбор"
        return 1
    fi
    
    # Генерация нового UUID
    NEW_UUID=$(xray uuid)
    
    # Добавляем клиента в серверный конфиг
    if [ "$config_type" = "1" ]; then
        # TLS конфиг
        PORT=443
        SECURITY="tls"
        TAG="tls"
        
        # Добавляем в серверный конфиг
        jq --arg uuid "$NEW_UUID" '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": "device-'$(date +%s)'"}]' \
           "$XRAY_CONFIG_DIR/config.json" > /tmp/xray_new.json
    else
        # Reality конфиг
        PORT=8443
        SECURITY="reality"
        TAG="reality"
        
        # Загружаем Reality ключи
        . /etc/xray/reality_keys
        
        # Добавляем в серверный конфиг
        jq --arg uuid "$NEW_UUID" '.inbounds[1].settings.clients += [{"id": $uuid, "flow": "", "email": "reality-device-'$(date +%s)'"}]' \
           "$XRAY_CONFIG_DIR/config.json" > /tmp/xray_new.json
    fi
    
    mv /tmp/xray_new.json "$XRAY_CONFIG_DIR/config.json"
    
    # Перезапускаем Xray
    systemctl restart xray
    
    # Создаём клиентский конфиг
    CONFIG_COUNT=$(find "$CLIENT_CONFIG_DIR" -name "*.json" 2>/dev/null | wc -l)
    NEW_CONFIG_NUM=$((CONFIG_COUNT + 1))
    
    if [ "$config_type" = "1" ]; then
        # TLS клиентский конфиг
        cat > "$CLIENT_CONFIG_DIR/client_$NEW_CONFIG_NUM.json" <<EOF
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "$NEW_UUID",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "serverName": "$DOMAIN",
        "fingerprint": "chrome"
      }
    }
  }]
}
EOF
    else
        # Reality клиентский конфиг
        cat > "$CLIENT_CONFIG_DIR/client_${NEW_CONFIG_NUM}_reality.json" <<EOF
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 8443,
        "users": [{
          "id": "$NEW_UUID"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "www.lovelawsblog.com",
        "fingerprint": "chrome",
        "publicKey": "$PUBLIC_KEY",
        "shortId": "$SHORT_ID1"
      }
    }
  }]
}
EOF
    fi
    
    echo "✅ Новый конфиг создан: client_$NEW_CONFIG_NUM.json"
    echo "UUID: $NEW_UUID"
    
    # Предлагаем сразу показать ссылку
    read -p "Показать ссылку для этого конфига? (y/N): " show_link
    if [[ "$show_link" =~ ^[Yy]$ ]]; then
        show_client_link "$NEW_CONFIG_NUM" "$config_type"
    fi
}

# === Показать ссылку клиента ===
show_client_link() {
    local config_num="$1"
    local config_type="$2"
    
    if [ -z "$config_num" ]; then
        # Показываем список конфигов
        mapfile -t config_files < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | sort)
        
        if [ ${#config_files[@]} -eq 0 ]; then
            echo "❌ Конфиги не найдены!"
            return 1
        fi
        
        echo -e "\nДоступные конфиги:"
        for i in "${!config_files[@]}"; do
            echo "$((i+1)). ${config_files[$i]##*/}"
        done
        
        read -p "Выберите конфиг (1-${#config_files[@]}): " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
            echo "Неверный выбор!"
            return 1
        fi
        
        selected="${config_files[$((choice-1))]}"
        config_num=$(basename "$selected" .json | sed 's/^client_//' | sed 's/_reality$//')
        
        # Определяем тип по имени файла
        if [[ "$selected" == *"_reality.json" ]]; then
            config_type="2"
        else
            config_type="1"
        fi
    fi
    
    # Загружаем Reality ключи если нужны
    if [ "$config_type" = "2" ] && [ -f /etc/xray/reality_keys ]; then
        . /etc/xray/reality_keys
    fi
    
    # Находим файл конфига
    if [ "$config_type" = "1" ]; then
        CONFIG_FILE="$CLIENT_CONFIG_DIR/client_$config_num.json"
    else
        CONFIG_FILE="$CLIENT_CONFIG_DIR/client_${config_num}_reality.json"
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ Конфиг не найден: $CONFIG_FILE"
        return 1
    fi
    
    # Извлекаем UUID
    UUID=$(grep -oP '(?<="id": ")[^"]+' "$CONFIG_FILE" | head -1)
    if [ -z "$UUID" ]; then
        echo "❌ Не удалось извлечь UUID из конфига"
        return 1
    fi
    
    # Генерируем ссылку
    if [ "$config_type" = "1" ]; then
        # TLS ссылка
        VLESS_URL="vless://${UUID}@${DOMAIN}:443?flow=xtls-rprx-vision&security=tls&type=tcp&fp=chrome&sni=${DOMAIN}#TLS-${config_num}"
    else
        # Reality ссылка
        VLESS_URL="vless://${UUID}@${DOMAIN}:8443?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.lovelawsblog.com&sid=${SHORT_ID1}#Reality-${config_num}"
    fi
    
    # Выбираем что показать
    echo -e "\nЧто показать?"
    echo "1. Только ссылку"
    echo "2. Ссылку и QR-код"
    echo "3. Полную информацию"
    read -p "Ваш выбор (1-3): " show_choice
    
    case $show_choice in
        1)
            echo -e "\nСсылка для импорта:"
            echo "$VLESS_URL"
            ;;
        2)
            echo -e "\nСсылка для импорта:"
            echo "$VLESS_URL"
            echo -e "\nQR-код:"
            qrencode -t UTF8 "$VLESS_URL" 2>/dev/null || echo "Установите qrencode для отображения QR-кода"
            ;;
        3)
            echo -e "\n=== Конфигурация клиента ==="
            echo "Домен: $DOMAIN"
            echo "Порт: $( [ "$config_type" = "1" ] && echo "443 (TLS)" || echo "8443 (Reality)" )"
            echo "UUID: $UUID"
            if [ "$config_type" = "1" ]; then
                echo "Протокол: VLESS + XTLS Vision"
                echo "Flow: xtls-rprx-vision"
                echo "Fingerprint: chrome"
                echo "SNI: $DOMAIN"
            else
                echo "Протокол: VLESS + Reality"
                echo "Public Key: $PUBLIC_KEY"
                echo "Short ID: $SHORT_ID1"
                echo "Dest: www.lovelawsblog.com:443"
            fi
            echo -e "\nСсылка для импорта:"
            echo "$VLESS_URL"
            echo -e "\nQR-код:"
            qrencode -t UTF8 "$VLESS_URL" 2>/dev/null || echo "Установите qrencode для отображения QR-кода"
            ;;
        *)
            echo "❌ Неверный выбор"
            ;;
    esac
}

# === Установка утилиты генерации ссылок ===
install_generate_script() {
    cat > "$GENERATE_SCRIPT" <<'EOF'
#!/bin/bash

CONFIG_DIR="/etc/xray/client_configs"
MARKER_FILE="/etc/xray/.installed"

if [ ! -f "$MARKER_FILE" ]; then
    echo "❌ Xray не установлен через этот скрипт"
    exit 1
fi

. "$MARKER_FILE"

echo "Выберите действие:"
echo "1. Показать ссылку для существующего конфига"
echo "2. Создать новый конфиг"
read -p "Ваш выбор (1-2): " action

case $action in
    1)
        # Показываем ссылку
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
        
        # Определяем тип конфига
        if [[ "$selected" == *"_reality.json" ]]; then
            . /etc/xray/reality_keys 2>/dev/null
            UUID=$(grep -oP '(?<="id": ")[^"]+' "$selected" | head -1)
            VLESS_URL="vless://${UUID}@${DOMAIN}:8443?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.lovelawsblog.com&sid=${SHORT_ID1}#$(basename "$selected" .json)"
        else
            UUID=$(grep -oP '(?<="id": ")[^"]+' "$selected" | head -1)
            VLESS_URL="vless://${UUID}@${DOMAIN}:443?flow=xtls-rprx-vision&security=tls&type=tcp&fp=chrome&sni=${DOMAIN}#$(basename "$selected" .json)"
        fi
        
        echo -e "\nСсылка:"
        echo "$VLESS_URL"
        echo -e "\nQR-код:"
        qrencode -t UTF8 "$VLESS_URL" 2>/dev/null || echo "Установите qrencode для отображения QR-кода"
        ;;
    2)
        echo "Для создания нового конфига запустите основной скрипт без аргументов"
        echo "или используйте пункт меню 'Создать новый конфиг'"
        ;;
    *)
        echo "Неверный выбор!"
        exit 1
        ;;
esac
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
    echo "Email: $EMAIL"
    
    # Статус Xray
    echo -e "\nСтатус Xray:"
    systemctl status xray --no-pager | grep -E "(Active:|Main PID:|CPU:)" | head -3
    
    # Открытые порты
    echo -e "\nОткрытые порты:"
    ss -tulpn | grep -E '(:443|:8443)' | while read line; do
        port=$(echo "$line" | grep -o ':\w\+' | head -1)
        echo "  $port"
    done
    
    # Клиентские конфиги
    local tls_count=$(find "$CLIENT_CONFIG_DIR" -name "*.json" ! -name "*_reality.json" 2>/dev/null | wc -l)
    local reality_count=$(find "$CLIENT_CONFIG_DIR" -name "*_reality.json" 2>/dev/null | wc -l)
    echo -e "\nКлиентских конфигов:"
    echo "  TLS: $tls_count"
    echo "  Reality: $reality_count"
    
    # Reality ключи если есть
    if [ -f /etc/xray/reality_keys ]; then
        . /etc/xray/reality_keys
        echo -e "\nReality Public Key: $PUBLIC_KEY"
        echo "Reality Short ID: $SHORT_ID1"
    fi
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
    rm -f /var/log/xray/{access.log,error.log} /etc/xray/reality_keys 2>/dev/null
    
    # Удаляем только нашу запись из cron
    if [ -n "$DOMAIN" ]; then
        local temp_cron=$(mktemp)
        crontab -l 2>/dev/null | grep -v "certbot renew.*$DOMAIN" > "$temp_cron" 2>/dev/null
        crontab "$temp_cron" 2>/dev/null
        rm -f "$temp_cron"
    fi
    
    # Отключаем порты в UFW
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow 80/tcp 2>/dev/null || true
    ufw delete allow 8443/tcp 2>/dev/null || true
    
    rm -f "$MARKER_FILE"
    echo "✅ Xray удален"
    echo "ℹ️  Сертификаты Let's Encrypt сохранены в /etc/letsencrypt/"
}

# === Главное меню ===
main_menu() {
    while true; do
        echo -e "\n==== XRAY МЕНЮ ===="
        echo "1. Показать информацию о сервере"
        echo "2. Показать ссылку/QR-код для конфига"
        echo "3. Создать новый конфиг"
        echo "4. Перезапустить Xray"
        echo "5. Удалить Xray"
        echo "6. Выйти"
        echo "===================="
        read -p "Выберите действие (1-6): " choice
        
        case $choice in
            1)
                show_server_info
                ;;
            2)
                show_client_link
                ;;
            3)
                generate_new_client_config
                ;;
            4)
                echo "🔄 Перезапуск Xray..."
                systemctl restart xray
                systemctl status xray --no-pager | head -5
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
    read -p "Количество начальных конфигов (0-10, 0 - без конфигов): " NUM_DEVICES
    
    # Валидация ввода
    if ! [[ "$NUM_DEVICES" =~ ^[0-9]+$ ]] || [ "$NUM_DEVICES" -gt 10 ]; then
        echo "❌ Неверное количество. Установлено значение 0"
        NUM_DEVICES=0
    fi
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

# Генерация Reality ключей
generate_reality_keys

# Генерация серверного конфига
generate_server_config

# Создаем начальные конфиги если нужно
if [ "$NUM_DEVICES" -gt 0 ]; then
    echo "📱 Создание $NUM_DEVICES начальных конфигов..."
    for i in $(seq 1 "$NUM_DEVICES"); do
        # Чередуем TLS и Reality
        if [ $((i % 2)) -eq 0 ]; then
            config_type="2"  # Reality
        else
            config_type="1"  # TLS
        fi
        
        NEW_UUID=$(xray uuid)
        
        # Добавляем в серверный конфиг
        if [ "$config_type" = "1" ]; then
            jq --arg uuid "$NEW_UUID" --arg email "initial-device-$i" \
               '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}]' \
               "$XRAY_CONFIG_DIR/config.json" > /tmp/xray_temp.json
        else
            jq --arg uuid "$NEW_UUID" --arg email "initial-reality-$i" \
               '.inbounds[1].settings.clients += [{"id": $uuid, "flow": "", "email": $email}]' \
               "$XRAY_CONFIG_DIR/config.json" > /tmp/xray_temp.json
        fi
        
        mv /tmp/xray_temp.json "$XRAY_CONFIG_DIR/config.json"
        
        # Создаем клиентский конфиг
        if [ "$config_type" = "1" ]; then
            cat > "$CLIENT_CONFIG_DIR/client_$i.json" <<EOF
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "$NEW_UUID",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "serverName": "$DOMAIN",
        "fingerprint": "chrome"
      }
    }
  }]
}
EOF
        else
            . /etc/xray/reality_keys
            cat > "$CLIENT_CONFIG_DIR/client_${i}_reality.json" <<EOF
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 8443,
        "users": [{
          "id": "$NEW_UUID"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "www.lovelawsblog.com",
        "fingerprint": "chrome",
        "publicKey": "$PUBLIC_KEY",
        "shortId": "$SHORT_ID1"
      }
    }
  }]
}
EOF
        fi
    done
    
    # Перезапускаем Xray
    systemctl restart xray
fi

install_generate_script

# Сохраняем данные установки
echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL" > "$MARKER_FILE"

echo -e "\n✅ Установка завершена!"
echo "========================================"
show_server_info
echo -e "\nИспользуйте:"
echo "  • $0 - для доступа к меню"
echo "  • generate_client_config - для генерации ссылок"
echo "========================================"

# Предлагаем создать первый конфиг если их нет
if [ "$NUM_DEVICES" -eq 0 ]; then
    read -p "Создать первый конфиг сейчас? (y/N): " create_first
    if [[ "$create_first" =~ ^[Yy]$ ]]; then
        generate_new_client_config
    fi
fi
