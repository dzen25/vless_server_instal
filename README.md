# Установка Xray VLESS + TLS

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
Удаленное выполнение:
```
bash -c "$(curl -fsSL https://github.com/dzen25/vless_server_instal/blob/main/install_xray.sh)"
```
Локальное выполнение:
```
git clone https://github.com/dzen25/vless_server_instal/&&cd vless_server_instal&&sudo bash install_xray.sh
```

## Интерактивный режим

```
sudo ./install_xray.sh
```

Скрипт запросит:

- Доменное имя (должно указывать на текущий сервер)

- Email (для Let's Encrypt)

- Количество устройств


После завершения установки можно выполнить:

generate_client_config и выбрать нужный конфиг — будет выведена VLESS-ссылка и QR-код.

---

## Headless режим (без взаимодействия)
```
sudo ./install_xray.sh --headless your.domain.com your@email.com 3
```

### Параметры:

- Домен

- Email для Let's Encrypt

- Количество клиентов

---

## Удаление

Вы можете удалить установку, выполнив:

```
sudo ./install_xray.sh
```
и выбрав пункт Удалить Xray.

---

## Выходные файлы:

Конфигурация сервера: /usr/local/etc/xray/config.json

Клиентские конфиги: /etc/xray/client_configs/*.json

Генератор ссылок: /usr/local/bin/generate_client_config

Логи: /var/log/xray/
