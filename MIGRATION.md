# Перенос проекта на новую инфраструктуру без потери данных

Проект: `cartoonews_laravel` (Laravel 10, PHP 8.1+)
Инфраструктура: `laravel-docker-server` (nginx + php-fpm + mariadb + redis + queue + certbot)

---

## 0. Что важно знать заранее

### 0.1. Где лежат файлы пользователей

В приложении используется диск `public_upload`:

```php
'public_upload' => [
    'driver' => 'local',
    'root' => public_path(),
],
```

Значит загруженные картинки лежат **в `public/`**, а не в `storage/`:

```
public/images/news_posters/...
public/images/news_content/...
public/build/...
```

В `.gitignore` проекта эти пути исключены:

```
public/images/*
public/build/*
```

**Вывод:** `git clone` их не принесёт. Копировать отдельно.

### 0.2. Что ещё не в git

| Путь | Содержимое |
|---|---|
| `.env` | APP_KEY, пароли БД/Redis/почты, ключи VK/Telegram |
| `public/images/` | все загруженные картинки |
| `public/build/` | собранные ассеты (Vite) |
| `storage/app/` | файлы диска `local` |
| `storage/logs/` | логи |
| `vendor/` | composer-зависимости |
| `node_modules/` | npm-зависимости |

### 0.3. Текущие настройки приложения

```
DB_CONNECTION=mysql
DB_DATABASE=cartoonews
DB_USERNAME=root
QUEUE_CONNECTION=database
CACHE_DRIVER=file
SESSION_DRIVER=file
FILESYSTEM_DISK=public
REDIS_PASSWORD=secret_redis
```

`QUEUE_CONNECTION=database` → задания в таблице `jobs`, отдельный Redis-воркер не обязателен.

---

## 1. Подготовка: бэкап старого сервера

Выполнять **на старом сервере**, до любых изменений.

### 1.1. Дамп базы

```bash
# имя контейнера БД на старом сервере уточнить: docker ps
docker exec mariadb_container sh -c \
  'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction \
   --routines --triggers --events cartoonews' \
  > /root/backup/cartoonews_$(date +%F).sql
```

Проверить, что дамп не пустой:

```bash
ls -lh /root/backup/cartoonews_*.sql
tail -5 /root/backup/cartoonews_*.sql   # должен быть "Dump completed"
```

### 1.2. Архив файлов

```bash
cd /path/to/cartoonews_laravel

tar -czf /root/backup/files_$(date +%F).tar.gz \
    .env \
    public/images \
    public/build \
    storage/app \
    storage/logs
```

Если `public/images` большая — архивировать отдельно и без сжатия:

```bash
tar -cf /root/backup/images_$(date +%F).tar public/images
```

### 1.3. Сохранить конфигурацию

```bash
cp /path/to/docker-compose.yml /root/backup/docker-compose.old.yml
docker compose config > /root/backup/compose-resolved.old.yml
docker volume ls > /root/backup/volumes.txt
```

### 1.4. Скачать бэкапы на локальную машину

```bash
scp root@SERVER:/root/backup/* ./backup/
```

**Не начинать миграцию, пока бэкапы не лежат локально.**

---

## 2. Развёртывание новой инфраструктуры

### 2.1. Структура на сервере

```
/opt/cartoonews/
├── docker-compose.yml        # из laravel-docker-server
├── .env                      # переменные инфраструктуры
├── nginx/
├── php/
├── scripts/
├── logs/
├── tmp/
└── src/                      # PROJECT_DIR — сюда код приложения
```

### 2.2. `.env` инфраструктуры

Создать `/opt/cartoonews/.env`:

```env
PROJECT_DIR=./src

# ВАЖНО: значения должны совпадать с текущими, если переиспользуется
# существующий volume mariadb_data (см. п. 2.4)
MYSQL_ROOT_PASSWORD=<текущий root-пароль>
MYSQL_DATABASE=cartoonews
MYSQL_USER=cartoonews
MYSQL_PASSWORD=<новый пароль приложения>

REDIS_PASSWORD=<текущий или новый пароль>

SERVER_NAME=cartoonews.ru
CERTBOT_EMAIL=admin@cartoonews.ru
```

### 2.3. Код приложения

```bash
cd /opt/cartoonews
git clone <repo> src
cd src
git checkout <нужный тег/ветку>
```

Либо скопировать текущий каталог, исключив мусор:

```bash
rsync -a --exclude vendor --exclude node_modules \
      /path/to/old/cartoonews_laravel/ /opt/cartoonews/src/
```

### 2.4. ⚠️ Критично: имя volume с базой

Compose создаёт volume как `<имя_проекта>_mariadb_data`. Имя проекта по умолчанию —
имя каталога с `docker-compose.yml`.

Если старый проект лежал в каталоге с другим именем, новый volume будет **пустым**,
и данные «пропадут» (на самом деле останутся в старом volume).

**Два варианта:**

**A. Переиспользовать старый volume** — задать фиксированное имя:

```yaml
volumes:
  mariadb_data:
    name: <старое_имя_volume>   # взять из /root/backup/volumes.txt
    driver: local
```

**B. Восстановить дамп в новый volume** (рекомендуется, чище):

```bash
docker compose up -d mariadb
# дождаться healthy
docker compose exec -T mariadb sh -c \
  'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" cartoonews' \
  < /root/backup/cartoonews_2026-10-20.sql
```

### 2.5. Учётные данные БД

Переменные `MYSQL_*` в compose применяются **только при первой инициализации**
volume. Если volume уже существует — они игнорируются.

Поэтому:

- при варианте **A** (старый volume) — оставить в `.env` приложения
  `DB_USERNAME=root` и текущий пароль, либо создать пользователя вручную:

```sql
CREATE USER 'cartoonews'@'%' IDENTIFIED BY '<пароль>';
GRANT ALL PRIVILEGES ON cartoonews.* TO 'cartoonews'@'%';
FLUSH PRIVILEGES;
```

- при варианте **B** (новый volume) — compose создаст пользователя сам,
  в `.env` приложения указать `DB_USERNAME=cartoonews`, `DB_PASSWORD=<MYSQL_PASSWORD>`.

### 2.6. `.env` приложения

Скопировать старый `.env` и изменить только то, что поменялось:

```bash
# .env входит в архив files_*.tar.gz, распакованный в п. 2.7
ls -l /opt/cartoonews/src/.env
```

Обязательно проверить:

```env
APP_KEY=base64:...          # НЕ менять — иначе сессии и шифрованные данные сломаются
APP_URL=https://cartoonews.ru
APP_ENV=production
APP_DEBUG=false

DB_HOST=mariadb
DB_DATABASE=cartoonews
DB_USERNAME=cartoonews      # или root, см. п. 2.5
DB_PASSWORD=...

REDIS_HOST=redis
REDIS_PASSWORD=...          # должен совпадать с REDIS_PASSWORD в compose .env

QUEUE_CONNECTION=database
```

### 2.7. Файлы пользователей

```bash
cd /opt/cartoonews/src
tar -xzf /root/backup/files_2026-10-20.tar.gz
```

Проверить:

```bash
ls public/images/news_posters | head
ls public/images/news_content | head
```

### 2.8. Симлинк storage

```bash
docker compose exec php php artisan storage:link
```

### 2.9. Зависимости и миграции

```bash
docker compose up -d --build

docker compose exec php composer install --no-dev --optimize-autoloader
docker compose exec php php artisan migrate --force
docker compose exec php php artisan config:cache
docker compose exec php php artisan route:cache
docker compose exec php php artisan view:cache
```

`migrate --force` применит только новые миграции. Существующие данные не тронет.

### 2.10. Ассеты

Если `public/build` перенесён из архива — сборка не нужна.

Если нет:

```bash
docker compose exec php npm ci
docker compose exec php npm run build
```

---

## 3. Проверка перед переключением

### 3.1. Контейнеры

```bash
docker compose ps
```

Все сервисы `healthy` (кроме `certbot` — он без healthcheck).

### 3.2. База

```bash
docker compose exec mariadb sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM cartoonews.news;"'
```

Сравнить с количеством на старом сервере.

### 3.3. Файлы

```bash
docker compose exec php sh -c 'ls public/images/news_posters | wc -l'
```

### 3.4. Приложение

```bash
curl -I https://cartoonews.ru
docker compose logs --tail=50 php
docker compose logs --tail=50 nginx
```

### 3.5. Очередь

```bash
docker compose logs --tail=20 queue
```

---

## 4. Переключение

1. Остановить старый стек:
   ```bash
   cd /path/to/old && docker compose down
   ```
   **`down` без `-v`** — volume с базой сохраняется.

2. Поднять новый:
   ```bash
   cd /opt/cartoonews && docker compose up -d
   ```

3. Проверить сайт, загрузку картинки, отправку формы.

4. Через сутки, если всё работает — удалить старый volume:
   ```bash
   docker volume rm <старое_имя_volume>
   ```

---

## 5. Откат

Если что-то сломалось:

```bash
cd /opt/cartoonews && docker compose down
cd /path/to/old && docker compose up -d
```

Старый volume не тронут, данные на месте.

---

## 6. Чек-лист

- [ ] Дамп БД снят и проверен (`Dump completed`)
- [ ] Архив `.env`, `public/images`, `public/build`, `storage/app` снят
- [ ] Бэкапы скачаны локально
- [ ] Имя старого volume зафиксировано
- [ ] `APP_KEY` перенесён без изменений
- [ ] `REDIS_PASSWORD` совпадает в compose `.env` и `.env` приложения
- [ ] `DB_USERNAME`/`DB_PASSWORD` соответствуют способу восстановления БД
- [ ] `public/images` распакованы
- [ ] `.env` приложения на месте, `APP_KEY` не изменён
- [ ] `php artisan storage:link` выполнен
- [ ] `php artisan migrate --force` выполнен
- [ ] Количество записей в БД совпадает
- [ ] Количество файлов совпадает
- [ ] Сайт открывается по HTTPS
- [ ] Загрузка картинки работает
- [ ] Очередь обрабатывает задания
- [ ] Старый стек остановлен без `-v`

---

## 7. Отличия новой инфраструктуры

| Параметр | Старое | Новое |
|---|---|---|
| SSL | вручную, файлы в `nginx/ssl` | Let's Encrypt, авто-продление |
| Порт 80 | проксировал PHP | ACME + 301 на HTTPS |
| MariaDB порт | `3306:3306` наружу | закрыт |
| Redis порт | `6379:6379` наружу | закрыт |
| Redis пароль | хардкод `secret_redis` | `${REDIS_PASSWORD}` |
| phpMyAdmin | `8080:80` наружу | `127.0.0.1:8080` |
| Очередь | не было сервиса | сервис `queue` |
| Cron | от root | от `www-data` |
| Лимит загрузки | 2M (PHP default) | 4G |
| Логи | без ротации | 10m × 3 |
| Healthchecks | нет | mariadb, redis, php, nginx |

---

## 8. Подводные камни

### 8.1. `APP_KEY`

Если сгенерировать новый — слетят сессии, сломаются зашифрованные поля
(в проекте есть `SECRET_VK`, `ACCESS_VK` в `.env` — они не шифруются, но
пользовательские данные могут). **Копировать как есть.**

### 8.2. `public/images` — не в git

`.gitignore` содержит `public/images/*`. При `git clone` папка будет пустой.
Единственный источник — архив со старого сервера.

### 8.3. `QUEUE_CONNECTION=database`

Задания лежат в таблице `jobs`. При переносе дампа они переедут вместе с базой.
Сервис `queue` в новом compose обработает их после старта.

Если в `jobs` накопились старые записи — проверить:

```bash
docker compose exec mariadb sh -c \
  'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM cartoonews.jobs;"'
```

### 8.4. `spatie/laravel-backup`

В `composer.json` есть пакет бэкапов. Если он настроен на S3 — проверить
`config/backup.php` и переменные `AWS_*` в `.env`.

### 8.5. `laravel/scout`

`SCOUT_DRIVER` по умолчанию `algolia`. Если в `.env` не задан — поиск
работает через `database` драйвер или отключён. После переноса проверить
поиск на сайте.

### 8.6. Права на файлы

`php/entrypoint.sh` выставляет `www-data` на `storage` и `bootstrap/cache`.
`public/images` он не трогает — если после распаковки архива владелец `root`,
загрузка новых картинок упадёт:

```bash
docker compose exec php chown -R www-data:www-data public/images public/build
```

### 8.7. `storage:link`

Симлинк `public/storage` → `storage/app/public` создаётся командой
`php artisan storage:link`. В `.gitignore` он есть, поэтому после `git clone`
его нет. Без него файлы диска `public` не отдаются.

В проекте основной диск — `public_upload` (пишет прямо в `public/`),
поэтому симлинк нужен только если где-то используется диск `public`.
