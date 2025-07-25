# Установка сервера Xray VLESS + TLS

## Описание

Скрипт `install_xray.sh` автоматически разворачивает Xray-сервер с VLESS-протоколом и TLS (Let's Encrypt), включая:

- Установку Xray и зависимостей
- Получение TLS-сертификата с помощью Certbot
- Создание серверной конфигурации (`config.json`)
- Генерацию уникальных UUID и клиентских конфигураций
- Генерацию VLESS-ссылок и QR-кодов для подключения
- Настройку брандмауэра (UFW)
- Установку крон-задачи для автоматического обновления сертификатов

Поддерживается как интерактивный, так и headless режим запуска.

На выходе будет несколько готовых конфигурационных файлов, с помощью которых вы сможете получить ссылку для подключения, а так же QR код.

---

## Установка и запуск
#### Примечание: Скрипт использует ufw с помощью  которого открывает 443/tcp порт и закрывает все остальные.
Перед установкой проверьте открытости 22 порта, что бы не потерять усправление, командой:
```
ufw status
```
Если ufw не активен или там нет 22 порта, откройте порт 22 командой:
```
ufw allow 22/tcp
```
И актививируйте ufw командой:
```
ufw enable
```
#### Удаленное выполнение:
```
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzen25/vless_server_instal/refs/heads/main/install_xray.sh)"
```
#### Локальное выполнение:
```
git clone https://github.com/dzen25/vless_server_instal/&&cd vless_server_instal&&sudo bash install_xray.sh
```

## Интерактивный режим

```
sudo bash install_xray.sh
```

Скрипт запросит:

- Доменное имя (должно указывать на текущий сервер)

- Email (для Let's Encrypt)

- Количество устройств


После завершения установки можно выполнить:
```
generate_client_config
```
 и выбрать нужный конфиг — будет выведена VLESS-ссылка и QR-код.

---

## Headless режим (без взаимодействия)
```
sudo bash install_xray.sh --headless your.domain.com your@email.com 3
```

### Параметры:

- Домен

- Email для Let's Encrypt

- Количество клиентов

---

## Удаление

Вы можете удалить установку, выполнив:

```
sudo bash install_xray.sh
```
введя случайные данные если затребует (исправится в следщем апдейте) и выбрав пункт Удалить Xray.

---

## Выходные файлы:

Конфигурация сервера: /usr/local/etc/xray/config.json

Клиентские конфиги: /etc/xray/client_configs/*.json

Генератор ссылок: /usr/local/bin/generate_client_config

Логи: /var/log/xray/
