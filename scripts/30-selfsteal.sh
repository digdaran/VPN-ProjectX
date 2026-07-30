#!/usr/bin/env bash
#
# 30-selfsteal.sh — self-steal сайт-донор для RU-ноды
#
# Разворачивает nginx на 127.0.0.1:8443 с настоящим сертификатом Let's Encrypt
# на ваш домен. Reality на порту 443 будет проксировать сюда активные зонды.
#
# Зачем: классический Reality с чужим SNI (www.microsoft.com) на российском
# хостинге даёт несоответствие SNI ↔ ASN — сертификат Microsoft, а IP
# российского провайдера. Это детектируемо. Self-steal убирает проблему
# целиком: домен → ваш IP → ваш сертификат → ваш реальный сайт.
#
#   sudo bash 30-selfsteal.sh --domain vpn.example.ru --email you@mail.com
#
set -euo pipefail

DOMAIN=""
EMAIL=""
WEBROOT="/var/www/selfsteal"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email)  EMAIL="$2";  shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"
[[ -n "$DOMAIN" ]] || die "Укажите --domain"
[[ -n "$EMAIL"  ]] || die "Укажите --email (для уведомлений Let's Encrypt)"

# ── Проверка DNS ───────────────────────────────────────────────────────────
log "Проверка DNS для $DOMAIN"
SERVER_IP="$(curl -4 -s --max-time 10 https://api.ipify.org || true)"
RESOLVED="$(dig +short A "$DOMAIN" @1.1.1.1 | tail -1 || true)"

[[ -n "$SERVER_IP" ]] || die "Не удалось определить внешний IP сервера"
[[ -n "$RESOLVED"  ]] || die "Домен $DOMAIN не резолвится. Создайте A-запись → $SERVER_IP"

if [[ "$RESOLVED" != "$SERVER_IP" ]]; then
  die "A-запись $DOMAIN указывает на $RESOLVED, а сервер имеет $SERVER_IP.
     Self-steal требует ТОЧНОГО совпадения — иначе сертификат не выпустится,
     и, что важнее, сохранится несоответствие, ради устранения которого всё и делается.
     Если используете Cloudflare — отключите проксирование (серое облако)."
fi
log "DNS корректен: $DOMAIN → $SERVER_IP"

# ── Порт 443 должен быть свободен для Xray, но занят ли он сейчас? ─────────
if ss -tlnp 2>/dev/null | grep -q ':443 '; then
  warn "Порт 443 уже кем-то занят. Если это Xray — нормально. Если nginx — он будет перенастроен."
fi

# ── Установка ──────────────────────────────────────────────────────────────
log "Установка nginx и certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx

systemctl stop nginx || true

# ── Сайт-заглушка ──────────────────────────────────────────────────────────
log "Разворачивание контента сайта"
mkdir -p "$WEBROOT" /var/www/certbot

cat > "$WEBROOT/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Инженерные заметки</title>
<meta name="description" content="Заметки о сетях, распределённых системах и эксплуатации инфраструктуры.">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📓</text></svg>">
<style>
:root{--bg:#fbfbfa;--fg:#1a1a19;--mut:#6b6b68;--acc:#2d5f8a;--brd:#e6e5e2}
@media(prefers-color-scheme:dark){:root{--bg:#16161a;--fg:#e9e9e6;--mut:#9a9a95;--acc:#7fb2dd;--brd:#2b2b30}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:16px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased}
.wrap{max-width:720px;margin:0 auto;padding:64px 24px 96px}
header{border-bottom:1px solid var(--brd);padding-bottom:24px;margin-bottom:40px}
h1{font-size:26px;margin:0 0 6px;letter-spacing:-.02em}
.sub{color:var(--mut);font-size:15px}
article{margin-bottom:36px}
h2{font-size:19px;margin:0 0 6px;letter-spacing:-.01em}
h2 a{color:var(--fg);text-decoration:none}
h2 a:hover{color:var(--acc)}
time{color:var(--mut);font-size:13px;font-variant-numeric:tabular-nums}
p{margin:8px 0 0;color:var(--mut)}
footer{border-top:1px solid var(--brd);margin-top:56px;padding-top:20px;color:var(--mut);font-size:13px}
a{color:var(--acc)}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>Инженерные заметки</h1>
  <div class="sub">Сети, распределённые системы, эксплуатация</div>
</header>

<article>
  <h2><a href="/">Балансировка нагрузки: consistent hashing на практике</a></h2>
  <time datetime="2026-07-14">14 июля 2026</time>
  <p>Разбираем, почему наивный <code>hash(key) % N</code> перестраивает почти всё кольцо при добавлении узла, и как виртуальные узлы выравнивают распределение.</p>
</article>

<article>
  <h2><a href="/">Тюнинг TCP на длинных RTT</a></h2>
  <time datetime="2026-06-28">28 июня 2026</time>
  <p>BBR против CUBIC на трансконтинентальных каналах: замеры, размеры буферов и почему <code>tcp_slow_start_after_idle</code> стоит выключить.</p>
</article>

<article>
  <h2><a href="/">Идемпотентность в очередях сообщений</a></h2>
  <time datetime="2026-06-05">5 июня 2026</time>
  <p>At-least-once доставка гарантирует дубликаты. Дедупликация по ключу на стороне потребителя и её стоимость в хранилище.</p>
</article>

<article>
  <h2><a href="/">Наблюдаемость: метрики, логи, трейсы</a></h2>
  <time datetime="2026-05-19">19 мая 2026</time>
  <p>Почему кардинальность меток убивает Prometheus быстрее, чем объём данных, и где проходит граница между метрикой и логом.</p>
</article>

<footer>
  © 2026 · <a href="/">Архив</a> · <a href="/">RSS</a>
</footer>
</div>
</body>
</html>
HTMLEOF

chown -R www-data:www-data "$WEBROOT" /var/www/certbot

# ── Временный конфиг для получения сертификата ─────────────────────────────
log "Получение сертификата Let's Encrypt"
cat > /etc/nginx/sites-available/selfsteal-acme <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { root $WEBROOT; index index.html; }
}
EOF
rm -f /etc/nginx/sites-enabled/default
# На случай повторного запуска после сбоя на предыдущей попытке: битый
# sites-enabled/selfsteal с прошлого раза иначе валит проверку уже здесь,
# до того как ниже дойдёт очередь его перезаписать.
rm -f /etc/nginx/sites-enabled/selfsteal
ln -sf /etc/nginx/sites-available/selfsteal-acme /etc/nginx/sites-enabled/selfsteal-acme
nginx -t || die "Временный конфиг nginx невалиден"
systemctl start nginx

certbot certonly --webroot -w /var/www/certbot \
  -d "$DOMAIN" --email "$EMAIL" \
  --agree-tos --non-interactive --no-eff-email \
  || die "Certbot не смог выпустить сертификат. Проверьте, что порт 80 доступен снаружи и DNS распространился."

log "Сертификат получен"

# ── Боевой конфиг ──────────────────────────────────────────────────────────
log "Применение боевого конфига nginx (127.0.0.1:8443)"
rm -f /etc/nginx/sites-enabled/selfsteal-acme

cat > /etc/nginx/sites-available/selfsteal <<EOF
server {
    # http2 через параметр listen (не отдельная директива "http2 on;") —
    # так работает и на старом nginx 1.18 из репозитория Ubuntu/Debian,
    # и на новом. Отдельная директива появилась только в nginx 1.25.1+
    # и ломает конфиг на всём, что старше.
    listen 127.0.0.1:8443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate         /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    root $WEBROOT;
    index index.html;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    access_log off;
    error_log /var/log/nginx/selfsteal_error.log crit;

    location / { try_files \$uri \$uri/ /index.html; }

    location ~* \.(?:css|js|jpg|jpeg|png|gif|ico|svg|woff2?)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location = /robots.txt {
        add_header Content-Type text/plain;
        return 200 "User-agent: *\nAllow: /\n";
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

ln -sf /etc/nginx/sites-available/selfsteal /etc/nginx/sites-enabled/selfsteal
nginx -t || die "Боевой конфиг nginx невалиден"
systemctl reload nginx
systemctl enable nginx

# ── Автообновление сертификата ─────────────────────────────────────────────
log "Настройка автообновления сертификата"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
# Xray читает сертификат только при старте Reality-хендшейка через dest,
# поэтому перезапуск ноды не требуется. Если используете TLS напрямую — раскомментируйте:
# docker restart remnanode 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer 2>/dev/null || true

# ── Проверка ───────────────────────────────────────────────────────────────
log "Локальная проверка"
if curl -sS -k --max-time 10 --resolve "$DOMAIN:8443:127.0.0.1" "https://$DOMAIN:8443/" -o /dev/null -w '%{http_code}\n' | grep -q 200; then
  log "nginx на 127.0.0.1:8443 отвечает 200"
else
  warn "nginx на 127.0.0.1:8443 не ответил 200 — проверьте /var/log/nginx/selfsteal_error.log"
fi

cat <<EOF

════════════════════════════════════════════════════════════════
  Self-steal готов
════════════════════════════════════════════════════════════════
  Домен      : $DOMAIN
  IP         : $SERVER_IP
  nginx      : 127.0.0.1:8443 (TLS) + 0.0.0.0:80 (ACME/redirect)
  Сертификат : /etc/letsencrypt/live/$DOMAIN/
  Контент    : $WEBROOT

  В конфиге Xray для этой ноды укажите:
      "dest"        : "127.0.0.1:8443"
      "serverNames" : ["$DOMAIN"]

  ⚠️  ЗАМЕНИТЕ содержимое $WEBROOT на что-то уникальное.
      Шаблон одинаков у всех, кто пользуется этим скриптом —
      а одинаковый контент на разных IP сам по себе является
      сигнатурой. Подойдёт любой реальный статический сайт:
      личный блог, портфолио, документация.

  ОБЯЗАТЕЛЬНАЯ ПРОВЕРКА с ВНЕШНЕГО хоста, после запуска Xray на 443:
      curl -sSI https://$DOMAIN/ | head -20
  Должен вернуться нормальный HTTP-ответ, а не TLS-ошибка.
  Если ошибка — вы уязвимы к активному зондированию (слой 3 DPI).
════════════════════════════════════════════════════════════════
EOF
