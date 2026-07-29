#!/usr/bin/env bash
#
# 10-panel-install.sh — Remnawave Panel (управляющий контур)
#
# Ставится на ОТДЕЛЬНЫЙ зарубежный VPS. Не на российский — база пользователей
# не должна лежать на узле, который могут изъять или заблокировать.
#
#   sudo bash 10-panel-install.sh \
#        --domain panel.example.com \
#        --sub-domain sub.example.com \
#        --email you@mail.com
#
# Требования: 2 vCPU, 4 GB RAM, 20 GB диска. Сначала прогоните 00-hardening.sh.
#
set -euo pipefail

DOMAIN=""; SUB_DOMAIN=""; EMAIL=""
DIR="/opt/remnawave"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
rnd()  { openssl rand -hex "${1:-32}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     DOMAIN="$2"; shift 2 ;;
    --sub-domain) SUB_DOMAIN="$2"; shift 2 ;;
    --email)      EMAIL="$2"; shift 2 ;;
    --dir)        DIR="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"
[[ -n "$DOMAIN" ]] || die "Укажите --domain"
[[ -n "$EMAIL"  ]] || die "Укажите --email"
SUB_DOMAIN="${SUB_DOMAIN:-$DOMAIN}"
command -v docker >/dev/null || die "Docker не установлен. Сначала прогоните 00-hardening.sh"

log "Проверка DNS"
SERVER_IP="$(curl -4 -s --max-time 10 https://api.ipify.org)"
for d in "$DOMAIN" "$SUB_DOMAIN"; do
  r="$(dig +short A "$d" @1.1.1.1 | tail -1 || true)"
  [[ -n "$r" ]] || die "Домен $d не резолвится"
  [[ "$r" == "$SERVER_IP" ]] || warn "$d → $r (сервер: $SERVER_IP). Норма, если включено проксирование Cloudflare."
done

apt-get update -qq && apt-get install -y -qq nginx certbot openssl

mkdir -p "$DIR"; cd "$DIR"

# ── Секреты ────────────────────────────────────────────────────────────────
log "Генерация секретов"
PG_PASS="$(rnd 24)"
JWT_AUTH="$(rnd 64)"
JWT_API="$(rnd 64)"
METRICS_PASS="$(rnd 16)"
WEBHOOK_SECRET="$(rnd 64)"

cat > "$DIR/.env" <<EOF
### БАЗА ###############################################
POSTGRES_USER=remnawave
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=remnawave
DATABASE_URL=postgresql://remnawave:$PG_PASS@remnawave-db:5432/remnawave

### ПРИЛОЖЕНИЕ #########################################
APP_PORT=3000
API_INSTANCES=1
METRICS_PORT=3001

JWT_AUTH_SECRET=$JWT_AUTH
JWT_API_TOKENS_SECRET=$JWT_API

### ДОМЕНЫ #############################################
FRONT_END_DOMAIN=$DOMAIN
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN

### МЕТРИКИ ############################################
METRICS_USER=metrics
METRICS_PASS=$METRICS_PASS

### ВЕБХУКИ ############################################
# Включите после того, как поднимете свой приёмник (api/webhook_server.py)
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://your-service.example.com/webhook
WEBHOOK_SECRET_HEADER=$WEBHOOK_SECRET

### ТЕЛЕГРАМ (опционально) #############################
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=
TELEGRAM_NOTIFY_USERS_CHAT_ID=
TELEGRAM_NOTIFY_NODES_CHAT_ID=
EOF
chmod 600 "$DIR/.env"

# ── docker-compose ─────────────────────────────────────────────────────────
log "Создание docker-compose.yml"
cat > "$DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-db:
    image: postgres:17
    container_name: remnawave-db
    hostname: remnawave-db
    restart: always
    env_file: .env
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks: [remnawave-network]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave:
    image: remnawave/backend:latest
    container_name: remnawave
    hostname: remnawave
    restart: always
    env_file: .env
    ports:
      - '127.0.0.1:3000:3000'
    networks: [remnawave-network]
    depends_on:
      remnawave-db:
        condition: service_healthy

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
    ports:
      - '127.0.0.1:3010:3010'
    networks: [remnawave-network]

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    name: remnawave-db-data
EOF

# ── Сертификат ─────────────────────────────────────────────────────────────
log "Получение сертификата"
systemctl stop nginx || true
mkdir -p /var/www/certbot
cat > /etc/nginx/sites-available/acme <<EOF
server {
    listen 80;
    server_name $DOMAIN $SUB_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/acme /etc/nginx/sites-enabled/acme
nginx -t && systemctl start nginx

CERT_DOMAINS="-d $DOMAIN"
[[ "$SUB_DOMAIN" != "$DOMAIN" ]] && CERT_DOMAINS="$CERT_DOMAINS -d $SUB_DOMAIN"
# shellcheck disable=SC2086
certbot certonly --webroot -w /var/www/certbot $CERT_DOMAINS \
  --email "$EMAIL" --agree-tos --non-interactive --no-eff-email \
  || die "Certbot не смог выпустить сертификат"

# ── nginx reverse proxy ────────────────────────────────────────────────────
log "Настройка reverse proxy"
rm -f /etc/nginx/sites-enabled/acme

cat > /etc/nginx/sites-available/remnawave <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# Панель управления. Публичный доступ сюда закрывать обязательно —
# см. блок с CIDR ниже или поставьте Cloudflare Access.
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "DENY" always;

    # РАСКОММЕНТИРУЙТЕ и впишите свои адреса, либо используйте Cloudflare Access:
    # allow 203.0.113.10;      # ваш домашний IP
    # allow 198.51.100.0/24;   # ваша VPN-сеть
    # deny all;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}

# Страница подписки. Должна быть публично доступна — сюда ходят клиенты.
server {
    listen 443 ssl;
    http2 on;
    server_name $SUB_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log off;

    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name $DOMAIN $SUB_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

ln -sf /etc/nginx/sites-available/remnawave /etc/nginx/sites-enabled/remnawave
nginx -t || die "Конфиг nginx невалиден"
systemctl reload nginx
systemctl enable nginx

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer 2>/dev/null || true

# ── Запуск ─────────────────────────────────────────────────────────────────
log "Запуск контейнеров"
cd "$DIR"
docker compose pull
docker compose up -d
sleep 15
docker compose ps

# ── Бэкап по расписанию ────────────────────────────────────────────────────
log "Настройка ежедневного бэкапа БД"
mkdir -p /opt/backups
cat > /usr/local/bin/remnawave-backup.sh <<EOF
#!/bin/bash
set -e
TS=\$(date +%Y%m%d-%H%M%S)
OUT=/opt/backups/remnawave-\$TS.sql.gz
docker exec remnawave-db pg_dump -U remnawave remnawave | gzip > "\$OUT"
find /opt/backups -name 'remnawave-*.sql.gz' -mtime +14 -delete
echo "backup: \$OUT"
EOF
chmod +x /usr/local/bin/remnawave-backup.sh
( crontab -l 2>/dev/null | grep -v remnawave-backup; echo "17 4 * * * /usr/local/bin/remnawave-backup.sh >> /var/log/remnawave-backup.log 2>&1" ) | crontab -

cat <<EOF

════════════════════════════════════════════════════════════════
  Панель развёрнута
════════════════════════════════════════════════════════════════
  Панель      : https://$DOMAIN
  Подписки    : https://$SUB_DOMAIN
  Секреты     : $DIR/.env  (chmod 600 — не коммитьте никуда)
  Бэкапы      : /opt/backups, ежедневно в 04:17 UTC, хранение 14 дней

  ⚠️  СЕЙЧАС ЖЕ откройте https://$DOMAIN и создайте суперадмина.
      Регистрация открыта до создания первого администратора —
      каждая минута промедления это открытая дверь.

  Затем:
   1. Ограничьте доступ к панели: раскомментируйте allow/deny
      в /etc/nginx/sites-available/remnawave либо настройте
      Cloudflare Access поверх.
   2. Settings → API Keys → создайте ключ для своего сервиса.
   3. Nodes → Management → + → добавьте ноды, скопируйте
      docker-compose.yml для каждой.
   4. Включите вебхуки в $DIR/.env, когда поднимете приёмник.

  Полезное:
      docker compose -f $DIR/docker-compose.yml logs -f
      docker exec -it remnawave remnawave --help
      /usr/local/bin/remnawave-backup.sh
════════════════════════════════════════════════════════════════
EOF
