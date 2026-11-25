# План переноса на новый Docker (`laravel-docker-server`)

Проект: `cartoonews_laravel`  
Целевая инфраструктура: `laravel-docker-server` (`nginx` + `certbot` + `php` + `queue` + `redis` + `mariadb` + `phpmyadmin`)  
Окно технических работ: **до 2 часов** (старый сайт можно остановить полностью).  
Дальнейший шаг после переноса: интеграция `cartoonews-telegram-scraper` (см. `cartoonews_laravel/TELEGRAM_INTEGRATION_PLAN.md`).

---

## Этап 1. Фиксация состояния и остановка старого стека

1. На сервере зафиксировать текущие контейнеры, volume и сети:
   ```bash
   docker ps
   docker volume ls
   docker network ls
   ```
   > Запомнить точное имя старого volume MariaDB и имя сети, в которой запущен `cartoonews-telegram-scraper` (обычно `<папка>_cartoon-network`).

2. Остановить веб-часть старого стека **без удаления volume**, чтобы во время бэкапа не появлялись новые данные и освободились порты `80`/`443`:
   ```bash
   cd /path/to/old-docker
   docker compose stop nginx php
   ```
   *(Либо `docker compose down`, а затем `docker compose up -d mariadb` только на время снятия дампа.)*

---

## Этап 2. Обязательный бэкап БД и файлов

**Переход к следующему этапу запрещён, пока не проверена целостность обоих бэкапов.**

### 2.1. Бэкап базы данных (`cartoonews`)
```bash
mkdir -p /root/backup

# Имя контейнера БД уточнить через docker ps
docker exec mariadb_container sh -c \
  'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction \
   --routines --triggers --events cartoonews' \
  > /root/backup/cartoonews_$(date +%F).sql
```
Проверка дампа:
```bash
ls -lh /root/backup/cartoonews_$(date +%F).sql
tail -n 5 /root/backup/cartoonews_$(date +%F).sql   # в конце должна быть строка "Dump completed"
```

### 2.2. Бэкап файлов проекта (вне git)
```bash
cd /path/to/old/cartoonews_laravel

tar -czf /root/backup/files_$(date +%F).tar.gz \
    .env \
    public/images \
    public/build \
    storage/app \
    storage/logs
```
Сохранить также старый `docker-compose.yml` и текущие SSL-сертификаты:
```bash
cp /path/to/old-docker/docker-compose.yml /root/backup/docker-compose.old.yml
tar -czf /root/backup/ssl_old_$(date +%F).tar.gz -C /path/to/old-docker nginx/ssl 2>/dev/null || true
```
Проверка архива файлов:
```bash
ls -lh /root/backup/files_$(date +%F).tar.gz
tar -tzf /root/backup/files_$(date +%F).tar.gz | head -n 20
```

### 2.3. Полная остановка старого стека
```bash
cd /path/to/old-docker
docker compose down   # БЕЗ флага -v! Старый volume должен остаться для отката
```

---

## Этап 3. Подготовка новой инфраструктуры

1. Развернуть каталог нового стека (например, `/opt/cartoonews`) из `laravel-docker-server`:
   - `docker-compose.yml`, `nginx/`, `php/`, `scripts/`
2. Поместить код `cartoonews_laravel` в `/opt/cartoonews/src` (`git clone` или `rsync` без `vendor` и `node_modules`).
3. Распаковать бэкап файлов в `/opt/cartoonews/src`:
   ```bash
   cd /opt/cartoonews/src
   tar -xzf /root/backup/files_$(date +%F).tar.gz
   ```
   Проверить наличие `.env`, `public/images/news_posters`, `public/images/news_content`, `public/build`.
4. Создать `/opt/cartoonews/.env` из `.env.example`:
   - `PROJECT_DIR=./src`
   - `SERVER_NAME=cartoonews.ru`
   - `CERTBOT_EMAIL=<email>`
   - `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE=cartoonews`, `MYSQL_USER=cartoonews`, `MYSQL_PASSWORD`
   - `REDIS_PASSWORD=<новый_надёжный_пароль>`
5. Проверить `/opt/cartoonews/src/.env`:
   - `APP_KEY` — **не менять** (оставить из старого `.env`);
   - `APP_ENV=production`, `APP_DEBUG=false`, `APP_URL=https://cartoonews.ru`;
   - `DB_HOST=mariadb`, `DB_DATABASE=cartoonews`, `DB_USERNAME=cartoonews`, `DB_PASSWORD=<MYSQL_PASSWORD>`;
   - `REDIS_HOST=redis`, `REDIS_PASSWORD=<REDIS_PASSWORD из /opt/cartoonews/.env>`;
   - `QUEUE_CONNECTION=database`.
6. **Убрать дублирующий запуск очереди из `cron`**:
   - В `app/Console/Kernel.php` удалить/закомментировать `$schedule->command('queue:work')->everyMinute()->withoutOverlapping();`, так как в новом `docker-compose.yml` работает отдельный контейнер `queue`.

---

## Этап 4. Сборка, восстановление БД и запуск

1. Собрать образы:
   ```bash
   cd /opt/cartoonews
   docker compose build
   ```
2. Поднять `mariadb` и дождаться статуса `healthy`:
   ```bash
   docker compose up -d mariadb
   docker compose ps
   ```
3. Восстановить дамп БД в новый volume:
   ```bash
   docker compose exec -T mariadb sh -c \
     'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" cartoonews' \
     < /root/backup/cartoonews_$(date +%F).sql
   ```
4. Поднять весь стек:
   ```bash
   docker compose up -d
   ```
5. Выполнить настройку приложения внутри контейнера `php`:
   ```bash
   docker compose exec php chown -R www-data:www-data public/images public/build
   docker compose exec php composer install --no-dev --optimize-autoloader
   docker compose exec php php artisan storage:link
   docker compose exec php php artisan migrate --force
   docker compose exec php php artisan config:cache
   docker compose exec php php artisan route:cache
   docker compose exec php php artisan view:cache
   ```

---

## Этап 5. Проверка после запуска

1. **Статус контейнеров**:
   ```bash
   docker compose ps
   ```
   `nginx`, `php`, `mariadb`, `redis`, `queue`, `phpmyadmin` — в статусе `Up` / `healthy`.
2. **SSL-сертификат**:
   ```bash
   docker compose logs --tail=30 certbot
   docker compose logs --tail=30 nginx
   ```
   Убедиться, что Let's Encrypt выпустил сертификат и `nginx` переключился на него.
3. **Сверка данных**:
   ```bash
   docker compose exec mariadb sh -c \
     'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM cartoonews.news;"'
   docker compose exec php sh -c 'ls public/images/news_posters | wc -l'
   ```
4. **Функциональная проверка**:
   - Открыть `https://cartoonews.ru`, проверить главную, страницу новости, поиск и картинки.
   - Войти в `/admindashboard`, проверить загрузку изображения и логи `docker compose logs --tail=30 queue`.

---

## Этап 6. Подготовка к интеграции Telegram и уборка

1. После подтверждения стабильной работы Laravel подключить сервисы `php` и `queue` в `docker-compose.yml` к внешней сети `cartoonews-telegram-scraper` (`cartoon-network`) и перейти к `TELEGRAM_INTEGRATION_PLAN.md`.
2. Старый каталог проекта, старый volume MariaDB и архивы в `/root/backup/` **не удалять минимум 24–48 часов** (для быстрого отката: `docker compose down` в новом → `docker compose up -d` в старом).
