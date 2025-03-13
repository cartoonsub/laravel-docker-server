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

# Установка и активация Redis
RUN pecl channel-update pecl.php.net \
    && pecl install redis \
    && docker-php-ext-enable redis

# Установка NodeJS
RUN curl -fsSL https://deb.nodesource.com/setup_21.x | bash - \
    && apt-get install -y nodejs

# Установка Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Установка Cron
# todo Перенести в отдельный контейнер или брать из файла crontab
RUN apt-get update && apt-get install -y cron
RUN echo "* * * * * cd /var/www/html && /usr/local/bin/php artisan schedule:run >> /dev/null 2>&1" | crontab -

# Установка часового пояса на Europe/Moscow
RUN ln -snf /usr/share/zoneinfo/Europe/Moscow /etc/localtime && echo "Europe/Moscow" > /etc/timezone

# Установка прав на директории
# todo - не работает, нужно разобраться. Возможно, папки создаются позже
RUN mkdir -p /var/www/html/storage/app/public \
    && mkdir -p /var/www/html/storage/framework/{cache,sessions,views} \
    && mkdir -p /var/www/html/storage/logs \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html/storage

# Установка рабочей директории
WORKDIR /var/www/html

# Обновление PATH
ENV PATH="/usr/local/bin:$PATH"

CMD ["sh", "-c", "cron && php-fpm"]