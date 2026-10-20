# laravel-docker-server

Docker-инфраструктура для Laravel: nginx + PHP-FPM + MariaDB + Redis + phpMyAdmin.

## SSL: автоматическое обновление сертификатов (Let's Encrypt)

Сертификаты выпускаются и продлеваются автоматически контейнером `certbot`
(webroot-валидация). Nginx сам перезагружается, когда сертификат обновился.

### Как это работает

1. `nginx` при старте рендерит `nginx/templates/default.conf.template` через `envsubst`
   (подставляет `${SERVER_NAME}`) в `/etc/nginx/conf.d/default.conf`.
2. Если сертификата ещё нет, генерируется временный self-signed сертификат на 1 день,
   чтобы nginx мог подняться.
3. `certbot` при старте запрашивает сертификат через `/.well-known/acme-challenge/`
   (файлы кладутся в общий volume `nginx/certbot/www`), затем каждые 12 часов
   выполняет `certbot renew`.
4. `nginx/entrypoint.sh` раз в минуту сравнивает сертификаты в
   `/etc/letsencrypt/live/<domain>/` с копией в `/etc/nginx/ssl/active/`.
   Если они изменились — копирует и делает `nginx -s reload`.

### Первый запуск

1. Домен должен уже указывать A-записью на IP сервера, порт 80 открыт.
2. Создайте `.env` из `.env.example` и заполните:

   ```env
   SERVER_NAME=example.com
   CERTBOT_EMAIL=admin@example.com
   ```

3. Запустите:

   ```bash
   docker compose up -d --build
   ```

4. Проверьте выпуск сертификата:

   ```bash
   docker compose logs -f certbot
   docker compose logs -f nginx
   ```

   Через ~1 минуту после выпуска nginx перезагрузится и начнёт отдавать
   настоящий сертификат.

### Проверка и ручное продление

```bash
# посмотреть срок действия
docker compose exec certbot certbot certificates

# принудительно продлить (обычно не нужно)
./scripts/renew_cert.sh
```

### Важно

- Каталоги `nginx/certbot/conf`, `nginx/certbot/www` и `nginx/ssl` — это состояние
  сервера, они в `.gitignore`. Не удаляйте их: там аккаунт Let's Encrypt и ключи.
- Старые вручную загруженные файлы в `nginx/ssl/` больше не используются —
  их можно удалить после успешного выпуска.
- Лимиты Let's Encrypt: 5 дубликатов сертификата в неделю. Не запускайте
  `--force-renewal` без необходимости.