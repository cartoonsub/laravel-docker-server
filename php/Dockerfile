FROM php:8.2-fpm

# Установка зависимостей и расширений
RUN apt-get update && apt-get install -y \
    git \
    zip \
    curl \
    sudo \
    unzip \
    libicu-dev \
    libbz2-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libonig-dev \
    libzip-dev \
    libwebp-dev \
    libvpx-dev \
    ffmpeg \
    procps \
    nano \
    tzdata \
    default-mysql-client \
    && docker-php-ext-configure gd --with-jpeg --with-freetype --with-webp \
    && docker-php-ext-install \
       bz2 \
       intl \
       iconv \
       bcmath \
       opcache \
       calendar \
       mbstring \
       pdo_mysql \
       zip \
       gd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Установка и активация Redis (версия зафиксирована для воспроизводимой сборки)
RUN pecl channel-update pecl.php.net \
    && pecl install redis-6.0.2 \
    && docker-php-ext-enable redis

# Кастомные настройки PHP (лимиты загрузки, opcache)
COPY php.ini /usr/local/etc/php/conf.d/zz-custom.ini

# Node.js 22 LTS + npm.
# Нужен в рантайм-образе: сборка ассетов (npm install / npm run build)
# выполняется прямо на сервере внутри контейнера.
# Node 21 был EOL (июнь 2024), 22 — актуальный LTS.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Composer из официального образа (без curl-инсталлятора)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Cron для планировщика Laravel
RUN apt-get update && apt-get install -y cron \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Расписание Laravel ставится в crontab www-data при старте контейнера
COPY crontab /usr/local/etc/laravel-crontab

# Установка часового пояса на Europe/Moscow
RUN ln -snf /usr/share/zoneinfo/Europe/Moscow /etc/localtime && echo "Europe/Moscow" > /etc/timezone

# Права на storage/bootstrap-cache выставляются в entrypoint.sh:
# bind-mount проекта перекрывает всё, что создано на этапе сборки.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN tr -d '\r' < /usr/local/bin/entrypoint.sh > /tmp/entrypoint.sh \
    && mv /tmp/entrypoint.sh /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /var/www/html

ENV PATH="/usr/local/bin:$PATH"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# php-fpm как PID 1 — корректный stop и рестарт при падении
CMD ["php-fpm"]