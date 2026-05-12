# 3x-ui + Caddy + Reality self-steal без Docker

Однострочный установщик для чистого VPS под root. Скрипт ставит последнюю версию 3x-ui из official GitHub release, ставит Caddy без Docker, создает сайт-заглушку в стиле Confluence и прячет панель за путём на том же домене:

```text
https://example.com/              -> сайт-заглушка
https://example.com/SECRET_PATH   -> 3x-ui panel
```

Схема портов:

```text
80/tcp   -> Caddy, HTTP challenge + redirect
443/tcp  -> Xray REALITY inbound из 3x-ui
4123/tcp -> Caddy HTTPS только на 127.0.0.1, self-steal target
2053/tcp -> 3x-ui panel только на 127.0.0.1
```

## Быстрый запуск

После публикации репозитория на GitHub команда будет такой:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/install.sh)
```

Или с параметрами без интерактива:

```bash
DOMAIN=example.com PANEL_PATH=SECRET_PATH bash <(wget -qO- https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/install.sh)
```

## Что делает скрипт

- Проверяет, что запущен от root.
- Проверяет DNS домена и предупреждает, если A-запись не указывает на текущий VPS.
- Устанавливает зависимости через `apt-get`.
- Ставит Caddy из стандартного репозитория Debian/Ubuntu.
- Скачивает latest release `MHSanaei/3x-ui` и устанавливает systemd service без Docker.
- Генерирует admin-логин, пароль, Reality private/public key, short id и UUID клиента.
- Настраивает 3x-ui panel на `127.0.0.1:2053` и base path `PANEL_PATH`.
- Создает VLESS TCP REALITY inbound на `443` с self-steal `dest=127.0.0.1:4123`.
- Создает Caddyfile: сайт-заглушка на домене и reverse proxy панели на секретном пути.
- Настраивает простой firewall через iptables: разрешены `22`, `80`, `443`.
- Включает BBR.
- Спрашивает, блокировать ли ICMP ping до сервера. По умолчанию `Y`.
- Спрашивает, отключать ли IPv6. По умолчанию `Y`.
- Печатает итоговый URL панели, логин/пароль и VLESS ссылку.

## Переменные

```bash
DOMAIN=example.com              # обязательный домен, если не введен интерактивно
PANEL_PATH=SECRET_PATH           # путь панели без ведущего slash
PANEL_PORT=2053                  # локальный порт панели
CADDY_STEAL_PORT=4123            # локальный HTTPS Caddy для self-steal
REALITY_PORT=443                 # публичный VLESS REALITY порт
SSH_PORT=22                      # порт SSH, который оставить открытым
INSTALL_FIREWALL=true            # true/false
ENABLE_BBR=true                  # true/false
BLOCK_ICMP_PING=true             # true/false, если задано - вопрос не задается
DISABLE_IPV6=true                # true/false, если задано - вопрос не задается
```

## После установки

Панель:

```text
https://DOMAIN/PANEL_PATH
```

Сайт-заглушка:

```text
https://DOMAIN/
```

Сервисы:

```bash
systemctl status x-ui
systemctl status caddy
```

Логи:

```bash
journalctl -u x-ui -n 100 --no-pager
journalctl -u caddy -n 100 --no-pager
```

Обновить 3x-ui:

```bash
x-ui update
```

## Важные замечания

- Домен должен заранее указывать A-записью на VPS.
- На чистом сервере порт `443` должен быть свободен: его займет Xray inbound из 3x-ui.
- Caddy получает сертификат через порт `80`, поэтому порт `80` должен быть доступен извне.
- Скрипт не отключает root SSH и не меняет SSH hardening, чтобы не закрыть доступ к VPS неожиданно.
- Это заготовка для личной инфраструктуры. Используй только там, где у тебя есть право администрировать сервер и домен.
