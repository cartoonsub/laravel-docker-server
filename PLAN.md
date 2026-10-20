# План исправления ошибок

Дата: 2026-10-20
Основание: повторный анализ репозитория `laravel-docker-server`.

Порядок фаз обязателен: сначала блокеры SSL и старта, затем надёжность, затем чистка.

---

## Фаза 1 — SSL и certbot

### 1.1. `nginx/certbot-entrypoint.sh` — skip-list домена

**Проблема.** Проверка заглушек:

```sh
if [ "$DOMAIN" = "localhost" ] || [ "$DOMAIN" = "yourdomain.com" ]; then
```

`example.com` из `.env.example` в список не входит. При запуске с дефолтным `.env`
certbot бесконечно пытается выпустить сертификат на несуществующий домен,
каждая попытка — запрос к Let's Encrypt.

**Исправление.** Заменить `if` на `case` и добавить все заглушки:

```sh
case "$DOMAIN" in
    localhost|127.0.0.1|example.com|www.example.com|yourdomain.com|www.yourdomain.com)
        echo "SERVER_NAME is a placeholder (${DOMAIN}), certbot disabled"
        exit 0
        ;;
esac
```

**Проверка.** `docker compose logs certbot` → `certbot disabled`.

---

### 1.2. `nginx/certbot-entrypoint.sh` — backoff при повторных попытках

**Проблема.** Фиксированная пауза 5 минут в бесконечном цикле. При неверном DNS
или закрытом порту 80 это бесконечный поток неудачных запросов.

**Исправление.** Экспоненциальная задержка с потолком 1 час:

```sh
DELAY=300
while [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; do
    if certbot certonly ...; then break; fi
    sleep "$DELAY" &
    wait $! || true
    if [ "$DELAY" -lt 3600 ]; then
        DELAY=$((DELAY * 2))
        [ "$DELAY" -gt 3600 ] && DELAY=3600
    fi
done
```

Последовательность: 5м → 10м → 20м → 40м → 1ч → 1ч → ...

**Проверка.** Логи содержат нарастающие интервалы.

---

### 1.3. `nginx/entrypoint.sh` — срок жизни временного сертификата

**Проблема.** `openssl req ... -days 1`. Если certbot не смог выпустить сертификат
в течение суток (DNS, firewall, rate-limit), временный сертификат истекает и
браузер показывает ошибку вместо сайта.

**Исправление.** `-days 30`.

**Проверка.** `openssl x509 -in nginx/ssl/active/fullchain.pem -noout -dates`.

---

### 1.4. `scripts/renew_cert.sh` — убрать безусловный `--force-renewal`

**Проблема.** Скрипт всегда передаёт `--force-renewal`. Каждый запуск создаёт новый
сертификат. Лимит Let's Encrypt — 5 дубликатов в неделю. Три-четыре запуска
блокируют домен на неделю.

**Исправление.** Флаг только по явному аргументу:

```sh
if [ "${1:-}" = "--force" ]; then
    docker compose exec -T certbot certbot renew --webroot -w /var/www/certbot --force-renewal
else
    docker compose exec -T certbot certbot renew --webroot -w /var/www/certbot
fi
```

**Проверка.** `./scripts/renew_cert.sh` без флага не создаёт новый сертификат
(`certbot certificates` показывает тот же serial).

---

## Фаза 2 — Устойчивость старта

### 2.1. `nginx/entrypoint.sh` — обнаружение падения nginx

**Проблема.** nginx запускается в фоне, entrypoint остаётся PID 1 и крутит цикл
проверки сертификатов. Если nginx упал (битый конфиг, занятый порт), контейнер
остаётся в состоянии `Up`, но сайт не отвечает. `restart: unless-stopped` не
срабатывает, потому что PID 1 жив.

**Исправление.** В цикле перед проверкой сертификатов:

```sh
if ! kill -0 "$NGINX_PID" 2>/dev/null; then
    echo "nginx exited unexpectedly, stopping container" >&2
    exit 1
fi
```

**Проверка.** `docker compose exec nginx kill -9 1` → контейнер перезапускается.

---

### 2.2. `docker-compose.yml` + `nginx/templates/default.conf.template` — развязать nginx от php

**Проблема.** Цепочка зависимостей:

```
mariadb (healthy) → php → nginx → certbot
```

MariaDB не поднялась → php не стартует → nginx не стартует → ACME challenge
недоступен → сертификат не выпустить и не продлить. Отказ БД блокирует SSL.

Причина зависимости — `fastcgi_pass php_server:9000;` резолвится при старте nginx.
Если хоста нет в DNS, nginx падает с `host not found in upstream`.

**Исправление.**

1. Убрать у `nginx` блок `depends_on: php`.
2. В шаблоне использовать отложенный резолвинг:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;
set $php_upstream php_server:9000;
...
fastcgi_pass $php_upstream;
```

`127.0.0.11` — встроенный DNS Docker.

**Проверка.** `docker compose stop php` → nginx продолжает отдавать статику и
ACME challenge, на PHP-запросы отвечает 502.

---

### 2.3. `docker-compose.yml` — `queue` без повторной сборки

**Проблема.** У сервиса `queue` одновременно `build` и `image`. Compose собирает
образ для каждого сервиса с `build`, то есть дважды.

**Исправление.** У `queue` оставить только `image`, зависимость от `php`:

```yaml
queue:
  image: laravel-docker-server/php:latest
  depends_on:
    php:
      condition: service_started
```

**Проверка.** `docker compose build` собирает образ один раз.

---

### 2.4. `docker-compose.yml` — fail-fast при пустом `REDIS_PASSWORD`

**Проблема.** Если `REDIS_PASSWORD` не задан, Compose подставляет пустую строку,
и Redis стартует с `--requirepass ""`, то есть без пароля.

**Исправление.**

```yaml
command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"]
```

**Проверка.** Запуск без переменной → ошибка конфигурации, а не открытый Redis.

---

### 2.5. `php/php.ini` — лимиты загрузки

**Проблема.** nginx: `client_max_body_size 100M`. PHP по умолчанию:
`upload_max_filesize=2M`, `post_max_size=8M`. Файлы больше 2 МБ отклоняются
PHP, хотя nginx их пропускает.

**Исправление.** Новый файл `php/php.ini`:

```ini
upload_max_filesize = 100M
post_max_size = 100M
memory_limit = 512M
max_execution_time = 300
max_input_time = 300
```

В `php/Dockerfile`:

```dockerfile
COPY php.ini /usr/local/etc/php/conf.d/zz-custom.ini
```

**Проверка.** `docker compose exec php php -i | grep -E "upload_max|post_max"`.

---

## Фаза 3 — Надёжность и эксплуатация

### 3.1. `docker-compose.yml` — healthchecks для php и nginx

**Проблема.** `depends_on: condition: service_healthy` у php ссылается на
mariadb и redis, но сами php и nginx не имеют healthcheck. Compose не знает,
готовы ли они принимать трафик.

**Исправление.**

```yaml
php:
  healthcheck:
    test: ["CMD-SHELL", "php -r 'exit(@fsockopen(\"127.0.0.1\",9000)?0:1);'"]
    interval: 15s
    timeout: 5s
    retries: 5
    start_period: 30s

nginx:
  healthcheck:
    test: ["CMD-SHELL", "wget -q -O /dev/null --no-check-certificate https://127.0.0.1/ || exit 1"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 20s
```

**Проверка.** `docker compose ps` → `healthy`.

---

### 3.2. `docker-compose.yml` — graceful stop для queue

**Проблема.** `queue:work` обрабатывает задачу; `docker stop` по умолчанию даёт
10 секунд, затем SIGKILL. Задача обрывается и может выполниться повторно.

**Исправление.**

```yaml
queue:
  stop_grace_period: 30s
```

**Проверка.** `docker compose stop queue` завершается без `Killed`.

---

### 3.3. `.gitignore` — сохранить `.gitkeep`

**Проблема.** Каталоги игнорируются целиком:

```
nginx/certbot/conf/
nginx/certbot/www/
```

`.gitkeep` внутри тоже игнорируется. На свежем клоне каталогов нет, Docker
создаёт их от root, и certbot не может писать.

**Исправление.**

```
nginx/certbot/conf/*
!nginx/certbot/conf/.gitkeep
nginx/certbot/www/*
!nginx/certbot/www/.gitkeep
```

**Проверка.** `git status` показывает `.gitkeep` как отслеживаемый файл.

---

### 3.4. `php/entrypoint.sh` — chown только при необходимости

**Проблема.** `chown -R www-data:www-data` на весь `storage` при каждом старте.
При накопленных логах и кэше это заметная задержка запуска.

**Исправление.** Проверять владельца перед рекурсивным изменением:

```sh
if [ "$(stat -c %U /var/www/html/storage 2>/dev/null)" != "www-data" ]; then
    chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
fi
```

**Проверка.** Второй запуск контейнера не выполняет `chown -R`.

---

### 3.5. `nginx/templates/default.conf.template` — таймауты и заголовки

**Проблема.** `fastcgi_read_timeout` по умолчанию 60 секунд — долгие запросы
(отчёты, импорт) обрываются с 504. Нет базовых security-заголовков.

**Исправление.** В блок `location ~ \.php$`:

```nginx
fastcgi_read_timeout 300s;
fastcgi_send_timeout 300s;
```

В `server` (443):

```nginx
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options SAMEORIGIN always;
add_header Referrer-Policy strict-origin-when-cross-origin always;
```

**Проверка.** `curl -I https://<domain>` содержит заголовки.

---

### 3.6. `php/Dockerfile` — фиксированная версия расширения redis

**Проблема.** `pecl install redis` без версии. Сборка невоспроизводима:
новая версия расширения может изменить поведение или сломать совместимость.

**Исправление.** `pecl install redis-6.0.2` (версию подтвердить перед применением).

**Проверка.** `docker compose exec php php -r 'echo phpversion("redis");'`.

---

## Фаза 4 — Чистка и документация

| # | Действие | Файл |
|---|---|---|
| 4.1 | Удалить мусорный файл | `test_llm_response.json` |
| 4.2 | Добавить раздел «Статус исправлений» с чекбоксами | `AUDIT.md` |
| 4.3 | Перенести в `docs/` или удалить устаревшие инструкции (`apt-key`, `focal`) | `docker install.txt`, `nginx docker install.txt`, `github_ssh.txt` |
| 4.4 | Описать `queue`, `RUN_CRON`, healthchecks, troubleshooting | `README.md` |
| 4.5 | Добавить `HEALTHCHECK` в образ (опционально, дублирует compose) | `nginx/Dockerfile` |

**Не трогать:** `sudo`, `nano`, `procps` в `php/Dockerfile` — сервер используется
как сборочная среда, эти утилиты нужны.

---

## Сводка

| Фаза | Пунктов | Приоритет | Оценка |
|---|---|---|---|
| 1 — SSL и certbot | 4 | 🔴 блокер | ~15 мин |
| 2 — Устойчивость старта | 5 | 🔴 блокер | ~25 мин |
| 3 — Надёжность | 6 | 🟠 важно | ~20 мин |
| 4 — Чистка | 5 | 🟡 косметика | ~10 мин |

**Порядок применения:** 1 → 2 → 3 → 4. Фазы 1 и 2 применяются одной пересборкой.

**Откат:** все изменения в файлах под git, кроме нового `php/php.ini`.
`git checkout -- .` и `docker compose up -d --build`.

**Риск в 2.2:** если `resolver 127.0.0.11` недоступен (не Docker DNS), nginx
вернёт 502 на PHP-запросы. Проверяется сразу после старта.

---

## Файлы, которые будут изменены

| Файл | Пункты |
|---|---|
| `nginx/certbot-entrypoint.sh` | 1.1, 1.2 |
| `nginx/entrypoint.sh` | 1.3, 2.1 |
| `scripts/renew_cert.sh` | 1.4 |
| `docker-compose.yml` | 2.2, 2.3, 2.4, 3.1, 3.2 |
| `nginx/templates/default.conf.template` | 2.2, 3.5 |
| `php/php.ini` (новый) | 2.5 |
| `php/Dockerfile` | 2.5, 3.6 |
| `php/entrypoint.sh` | 3.4 |
| `.gitignore` | 3.3 |
| `README.md`, `AUDIT.md` | 4.2, 4.4 |
