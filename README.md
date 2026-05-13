# 3x-ui + Caddy + Reality self-steal без Docker

Однострочный установщик для чистого VPS под root. Скрипт ставит последнюю версию 3x-ui из official GitHub release, ставит Caddy без Docker, создает сайт-заглушку в стиле Confluence и выносит панель на отдельный HTTPS-порт:

```text
https://example.com/              -> сайт-заглушка
https://example.com:8443/SECRET_PATH/ -> 3x-ui panel
```

Схема портов:

```text
80/tcp   -> Caddy, HTTP challenge + redirect
443/tcp  -> Xray REALITY inbound из 3x-ui
8443/tcp -> Caddy public HTTPS reverse proxy к панели
4123/tcp -> Caddy HTTPS только на 127.0.0.1, self-steal target
2053/tcp -> 3x-ui panel только на 127.0.0.1
```

## Быстрый запуск

Интерактивный запуск:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/DarkSidr/xui/main/install.sh)
```

Или с параметрами без интерактива:

```bash
DOMAIN=example.com PANEL_PATH=SECRET_PATH bash <(wget -qO- https://raw.githubusercontent.com/DarkSidr/xui/main/install.sh)
```

Полностью без вопросов:

```bash
DOMAIN=example.com PANEL_PATH=SECRET_PATH BLOCK_ICMP_PING=true DISABLE_IPV6=true bash <(wget -qO- https://raw.githubusercontent.com/DarkSidr/xui/main/install.sh)
```

Только запрет ping и отключение IPv6 без установки 3x-ui/Caddy:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/DarkSidr/xui/main/vps-hardening.sh)
```

## Что делает скрипт

- Проверяет, что запущен от root.
- Проверяет DNS домена и предупреждает, если A-запись не указывает на текущий VPS.
- Устанавливает зависимости через `apt-get`.
- Ставит Caddy из стандартного репозитория Debian/Ubuntu.
- Скачивает latest release `MHSanaei/3x-ui` и устанавливает systemd service без Docker.
- Генерирует admin-логин, пароль, Reality private/public key, short id и UUID клиента.
- Генерирует `subId` для первого клиента и печатает ссылку подписки.
- Настраивает 3x-ui panel на `127.0.0.1:2053` и base path `PANEL_PATH`.
- Создает VLESS TCP REALITY inbound на `443` с self-steal `dest=127.0.0.1:4123`.
- Создает Caddyfile: сайт-заглушка на домене и reverse proxy панели на `8443`.
- Настраивает простой firewall через iptables: разрешены `22`, `80`, `443`, `8443`.
- Включает BBR.
- Спрашивает, блокировать ли ICMP ping до сервера. По умолчанию `Y`.
- Спрашивает, отключать ли IPv6. По умолчанию `Y`.
- Печатает итоговый URL панели, логин/пароль, VLESS ссылку и ссылку подписки.

## Переменные

```bash
DOMAIN=example.com              # обязательный домен, если не введен интерактивно
PANEL_PATH=SECRET_PATH           # путь панели без ведущего slash
PANEL_PORT=2053                  # локальный порт панели
PANEL_PUBLIC_PORT=8443           # публичный HTTPS-порт панели через Caddy
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
https://DOMAIN:8443/PANEL_PATH/
```

Если открыть путь панели без завершающего `/`, Caddy перенаправит на правильный URL.

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
- Панель открывается на `8443`, поэтому этот порт должен быть доступен извне.
- Caddy получает сертификаты через порт `80`, поэтому порт `80` должен быть доступен извне.
- Если сломать Reality inbound на `443`, сайт-заглушка может перестать открываться, но панель на `8443` останется доступна.
- Скрипт не отключает root SSH и не меняет SSH hardening, чтобы не закрыть доступ к VPS неожиданно.
- Это заготовка для личной инфраструктуры. Используй только там, где у тебя есть право администрировать сервер и домен.

## Отдельный VPS hardening

`vps-hardening.sh` можно запускать отдельно на VPS, если нужен только минимальный сетевой hardening:

- включает `net.ipv4.icmp_echo_ignore_all = 1`;
- отключает IPv6 через `net.ipv6.conf.*.disable_ipv6 = 1`;
- добавляет runtime-правило `iptables` для drop IPv4 ICMP echo-request, если `iptables` установлен;
- сохраняет sysctl-настройки в `/etc/sysctl.d/99-vps-hardening.conf`.
