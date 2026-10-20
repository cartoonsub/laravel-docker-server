# Аудит проекта `laravel-docker-server`

Дата проведения аудита: 27 сентября 2026 г.  
Объект аудита: Docker-инфраструктура для развёртывания Laravel-приложений.

---

## 1. Общее резюме

Репозиторий представляет собой стек контейнеризации на базе Docker Compose, включающий в себя:
* **Nginx** (веб-сервер и SSL-терминация)
* **PHP 8.2-FPM** (бэкенд-рантайм, утилиты сборщика, планировщик cron)
* **MariaDB 11.7.2** (реляционная СУБД)
* **Redis** (in-memory кэш и брокер очередей)
* **phpMyAdmin** (веб-интерфейс администрирования БД)

В ходе анализа выявлены **критические дефекты конфигурации**, препятствующие нормальному запуску и отдаче контента, **угроза безвозвратной потери данных**, **сетевые уязвимости** и **архитектурные недостатки сборки образов**.

---

## 2. Критические ошибки (Severity: Critical)

### 2.1. Несовпадение путей и сертификатов SSL в `nginx/nginx.conf`
* **Файл:** `nginx/nginx.conf` (строки 44–45), директория `nginx/ssl/`
* **Проблема:** В конфигурации Nginx прописаны пути:
  ```nginx
  ssl_certificate /etc/nginx/ssl/cert.crt;
  ssl_certificate_key /etc/nginx/ssl/sitekey.key;
  ```
  В директории `nginx/ssl/` на самом деле находятся файлы: `cartoonews.ru.crt` и `cartoonews.ru.key`.
* **Последствие:** Nginx завершается с фатальной ошибкой `BIO_new_file failed: No such file or directory` и контейнер аварийно останавливается при старте.
* **Решение:** Привести имена файлов к единому стандарту либо передавать пути/домен через переменные окружения.

---

### 2.2. Ошибка отдачи стилей и скриптов (JS/CSS) в `nginx/nginx.conf`
* **Файл:** `nginx/nginx.conf` (строки 34–37, 68–71)
* **Проблема:** Блок обработки статики содержит взаимоисключающие заголовки и нарушает отдачу файлов:
  ```nginx
  location ~* \.(js|css)$ {
      add_header Content-Type application/javascript;
      add_header Content-Type text/css;
  }
  ```
* **Последствия:**
  1. Всем файлам `.js` и `.css` отправляются одновременно два разных `Content-Type`.
  2. Отсутствует `try_files $uri =404;` или передача на диск.
  3. Современные браузеры блокируют такие ресурсы из-за политики `Strict MIME type checking`.
  4. Nginx уже содержит корректные соответствия типов по умолчанию через директиву `include mime.types;`.
* **Решение:** Полностью удалить данный блок либо заменить его на корректную настройку кеширования статики:
  ```nginx
  location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|webp)$ {
      expires max;
      log_not_found off;
      access_log off;
      try_files $uri =404;
  }
  ```

---

### 2.3. Риск потери базы данных в `cleanup.sh`
* **Файл:** `cleanup.sh` (строка 5)
* **Проблема:** Скрипт очистки содержит команду:
  ```bash
  docker volume prune -f
  ```
* **Последствие:** Команда принудительно удаляет **все неиспользуемые Docker volumes**. Если скрипт сработает по расписанию (cron) в момент, когда контейнер СУБД временно остановлен (перезапуск, обновление образа, снятие бэкапа), **том `mariadb_data` со всеми данными будет стёрт навсегда**.
* **Решение:** Немедленно удалить `docker volume prune -f` из автоматических скриптов очистки на хосте.

---

### 2.4. Неработающие переменные окружения в `nginx/nginx.conf`
* **Файл:** `nginx/nginx.conf` (строки 11, 42)
* **Проблема:** Использование `$SERVER_NAME` и `$SSL_SERVER_NAME` в директивах `server_name`:
  ```nginx
  server_name $SERVER_NAME;
  ...
  server_name $SSL_SERVER_NAME;
  ```
* **Последствие:** Nginx не считывает системные переменные окружения напрямую из конфигурационных файлов. Он воспринимает эту запись буквально как строковое доменное имя `$SERVER_NAME`.
* **Решение:** Использовать стандартный механизм шаблонов Docker-образа Nginx: поместить конфигурацию в `nginx/templates/default.conf.template`, чтобы Nginx на старте обработал её через `envsubst`.

---

## 3. Проблемы безопасности (Severity: High)

### 3.1. Публикация внутренних служебных портов на `0.0.0.0`
* **Файл:** `docker-compose.yml` (порты `3306:3306`, `6379:6379`, `8080:80`)
* **Проблема:** Порты MariaDB, Redis и phpMyAdmin открыты во внешний мир на всех сетевых интерфейсах хоста.
* **Последствие:** Сервисы доступны для сканеров портов, ботнетов и брутфорс-атак из интернета. PHP общается с MariaDB и Redis внутри изолированной сети `webnet`, поэтому публикация этих портов на хосте не требуется.
* **Решение:**
  * Убрать секцию `ports` у `mariadb` и `redis` (или явно забиндить на `127.0.0.1`, если требуется локальный доступ: `"127.0.0.1:3306:3306"`).
  * Сервис `phpmyadmin` отключить на проде или защитить Basic Auth через Nginx.

---

### 3.2. Захардкоженный пароль Redis
* **Файл:** `docker-compose.yml` (строки 36–37)
* **Проблема:** Пароль `secret_redis` зашит прямо в манифест Compose:
  ```yaml
  environment:
    - REDIS_PASSWORD=secret_redis
  command: ["redis-server", "--requirepass", "secret_redis"]
  ```
* **Решение:** Вынести пароль в переменную окружения `${REDIS_PASSWORD}` в файл `.env`.

---

### 3.3. Небезопасные пароли по умолчанию в `.env.example`
* **Файл:** `.env.example`
* **Проблема:** Использование паролей `admin` для `MYSQL_ROOT_PASSWORD` и `MYSQL_PASSWORD`.
* **Решение:** Использовать безопасные плейсхолдеры (например, `change_this_to_a_strong_password`) во избежание развертывания продакшена с дефолтными учетными данными.

---

### 3.4. Отсутствие HTTPS-редиректа
* **Файл:** `nginx/nginx.conf`
* **Проблема:** Порт 80 дублирует логику обработки PHP вместо постоянного 301-редиректа на HTTPS.
* **Решение:** В блоке `listen 80;` настроить безусловный редирект:
  ```nginx
  return 301 https://$host$request_uri;
  ```

---

### 3.5. Отсутствие автоматического выпуска и обновления SSL-сертификатов
* **Файл:** `docker-compose.yml`, `nginx/nginx.conf`
* **Проблема:** Сертификаты хранятся в виде статичных локальных файлов в `nginx/ssl/`. В проекте отсутствует механизм автоматического выпуска и периодического продления SSL-сертификатов (Let's Encrypt / ZeroSSL).
* **Последствие:** Сертификаты Let's Encrypt действуют 90 дней. Без автоматического продления сайт станет недоступен с ошибкой безопасности браузера (`SSL_ERROR_EXPIRED`), а ручная замена требует постоянного внимания и несет риск простоев.
* **Решение:**
  1. Добавить контейнер `certbot` в `docker-compose.yml`.
  2. Выделить общий volume между Nginx и Certbot для прохождения ACME challenge (`/var/www/certbot` -> `/.well-known/acme-challenge/`).
  3. Настроить периодический запуск проверки `certbot renew` и последующую перезагрузку конфигурации Nginx (`nginx -s reload`).

---

## 4. Архитектура и контейнеризация (Severity: Medium)

### 4.1. Неработающий `chmod`/`chown` в `php/Dockerfile`
* **Файл:** `php/Dockerfile` (строки 60–65)
* **Проблема:** Разработчик оставил комментарий `# todo - не работает, нужно разобраться`.
  Команды `RUN mkdir ... && chown -R www-data:www-data /var/www/html` выполняются на этапе сборки образа (`docker build`). В `docker-compose.yml` директория проекта монтируется как bind-mount:
  ```yaml
  volumes:
    - ${PROJECT_DIR}:/var/www/html
  ```
  Монтирование каталога с хоста перекрывает права и файлы, созданные внутри образа при сборке.
* **Решение:** Использовать стартовый скрипт `docker-entrypoint.sh`, выполняющий проверку и установку прав при инициализации контейнера, либо синхронизировать UID/GID пользователя хоста и контейнера.

---

### 4.2. Нарушение принципа единой ответственности (Fat Container)
* **Файл:** `php/Dockerfile`
* **Проблема:** В один образ установлены:
  * PHP 8.2 FPM
  * Node.js v21 + npm
  * Composer
  * Cron
  * Утилиты (procps, nano, sudo, ffmpeg)
* **Последствия:**
  * Образ имеет избыточный размер (> 1.5 ГБ).
  * Node.js 21 — устаревшая версия (non-LTS, EOL в 2024 году). В рантайме PHP фронтенд-сборщик не нужен.
  * Cron запущен через `CMD ["sh", "-c", "cron && php-fpm"]`. При аварийном падении cron контейнер не перезапустится, так как PID 1 принадлежит sh/php-fpm.
  * Cron выполняется от `root`, из-за чего логи и кэш Laravel в `storage/` получают владельца `root:root`, вызывая ошибку `Permission denied` при веб-запросах.
  * Файл `php/crontab` фактически не используется, расписание захардкожено прямо в Dockerfile.
* **Решение:**
  * Исключить Node.js из production-образа PHP (собирать ассеты через multi-stage build или CI/CD).
  * Вынести планировщик задач Laravel в отдельный легкий сервис или запускать его под пользователем `www-data`.
  * Устанавливать Composer копированием из официального образа:
    ```dockerfile
    COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
    ```

---

### 4.3. Отсутствие воркера очередей (Queue Worker)
* В стеке отсутствует сервис обработки очередей Laravel (`php artisan queue:work` или Supervisor/Horizon). Фоновые задачи, отправка email и обработка тяжелых процессов не смогут выполняться асинхронно.

---

### 4.4. Отсутствие Healthchecks и зависимости запуска
* Контейнеры не содержат директив `healthcheck`. Если сервис `php` запустится раньше, чем СУБД `mariadb` успеет пройти этап инициализации сокетов, выполнение миграций или первоначальных скриптов завершится ошибкой.
* Рекомендуется добавить `healthcheck` для MariaDB и Redis и указать в PHP:
  ```yaml
  depends_on:
    mariadb:
      condition: service_healthy
    redis:
      condition: service_healthy
  ```

---

### 4.5. Неограниченный размер логов Docker
* В сервисах `docker-compose.yml` не заданы параметры ротации логов. При высокой нагрузке логи контейнеров Nginx, PHP и MariaDB могут забить дисковое пространство сервера.
* Решение — добавить в сервисы секцию логирования:
  ```yaml
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"
  ```

---

## 5. Документация и организация репозитория (Severity: Low)

1. **Файлы заметок с пробелами в именах:**
   * В корне находятся файлы `docker install.txt`, `nginx docker install.txt`, `github_ssh.txt`.
   * Содержат устаревшие команды: использование утилиты `apt-key add` (объявлена deprecated в современных версиях Debian/Ubuntu), привязка к дистрибутиву `ubuntu focal` (20.04), генерация устаревших RSA-ключей вместо `ed25519`.
   * Рекомендуется перенести полезную информацию в `README.md` или папку `docs/`, удалив устаревшие `.txt` файлы.
2. **Пустой `README.md`:**
   * Отсутствует пошаговое руководство по первому запуску проекта, генерации ключей приложения (`key:generate`), запуску миграций и настройке SSL.
3. **Неактуальный `.gitignore`:**
   * Содержит записи для старых версий Laravel 4, Vagrant и Homestead.
   * Не игнорирует локальную папку логов `logs/`.

---

## 6. Рекомендуемый план действий

| Шаг | Действие | Статус / Приоритет |
| :--- | :--- | :--- |
| **1** | Удалить `docker volume prune -f` из `cleanup.sh` для предотвращения потери данных БД | 🔴 Немедленно |
| **2** | Исправить `nginx/nginx.conf`: удалить сломанный блок JS/CSS, настроить пути к SSL и редирект с 80 порта | 🔴 Высокий |
| **3** | Закрыть порты `3306` и `6379` в `docker-compose.yml`, спрятать phpMyAdmin | 🟠 Высокий |
| **4** | Вынести пароль Redis и переменные домена в `.env` / `docker-compose.yml` | 🟠 Высокий |
| **5** | Настроить автоматический выпуск и обновление SSL-сертификатов (Certbot / Let's Encrypt + auto-reload Nginx) | 🟠 Высокий |
| **6** | Настроить `docker-entrypoint.sh` для корректной установки прав на директории Laravel (`storage`, `bootstrap/cache`) | 🟡 Средний |
| **7** | Разделить запуск `php-fpm`, `cron` и `queue:work` на уровне Docker Compose | 🟡 Средний |
| **8** | Актуализировать `README.md` и перенести документацию из `.txt` файлов | 🟢 Низкий |

---

### 6.1. Архитектурная схема автоматического обновления SSL (Certbot)

Для реализации автоматического выпуска и продления сертификатов рекомендуется:

1. **В `docker-compose.yml` добавить сервис `certbot` и общие тома с Nginx:**
   ```yaml
   services:
     nginx:
       # ...
       volumes:
         - ${PROJECT_DIR}:/var/www/html
         - ./nginx/nginx.conf:/etc/nginx/nginx.conf
         - ./certbot/conf:/etc/letsencrypt:ro
         - ./certbot/www:/var/www/certbot:ro
       # Периодическая проверка и перезагрузка Nginx при обновлении сертификатов
       command: '/bin/sh -c ''while :; do sleep 6h & wait $${!}; nginx -s reload; done & nginx -g "daemon off;"'''

     certbot:
       image: certbot/certbot:latest
       container_name: certbot_container
       restart: unless-stopped
       volumes:
         - ./certbot/conf:/etc/letsencrypt
         - ./certbot/www:/var/www/certbot
       # Автоматическая попытка обновления сертификатов каждые 12 часов
       entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot; sleep 12h & wait $${!}; done;'"
   ```

2. **В `nginx/nginx.conf` добавить обработку ACME-вызова:**
   ```nginx
   server {
       listen 80;
       server_name $SERVER_NAME;

       # Маршрут для подтверждения владения доменом от Let's Encrypt
       location /.well-known/acme-challenge/ {
           root /var/www/certbot;
       }

       location / {
           return 301 https://$host$request_uri;
       }
   }
   ```

3. **Скрипт первичной инициализации сертификатов:**
   Подготовить однократную команду (или скрипт `init-letsencrypt.sh`) для генерации первого сертификата:
   ```bash
   docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
       -d yourdomain.com -d www.yourdomain.com \
       --email admin@yourdomain.com --agree-tos --no-eff-email
   ```

