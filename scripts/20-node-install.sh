#!/usr/bin/env bash
#
# 20-node-install.sh — Remnawave Node (Remnanode) на любой узел
#
# Ставится и на российскую входную ноду, и на все зарубежные выходные.
#
#   sudo bash 20-node-install.sh --panel-ip 1.2.3.4 --node-port 2222
#
# Порядок:
#   1. В панели: Nodes → Management → + → создайте ноду (имя, адрес, порт —
#      тот же, что в --node-port), нажмите "Copy docker-compose.yml"
#   2. Запустите этот скрипт
#   3. Из скопированного в п.1 текста возьмите ТОЛЬКО значение SECRET_KEY
#      и вставьте его в /opt/remnanode/.env
#   4. cd /opt/remnanode && docker compose up -d
#
# ВАЖНО: у remnawave/node НЕТ переменной SSL_CERT — образ ждёт NODE_PORT и
# SECRET_KEY (проверено на реальном контейнере: без них падает с
# "NODE_PORT: Required" / "SECRET_KEY: Required").
#
# УТОЧНЕНИЕ (2026-08-14): раньше здесь было написано, что SECRET_KEY
# доступен только через UI-кнопку "Copy docker-compose.yml" — это оказалось
# не так. SECRET_KEY общий на всю панель (не привязан к конкретной ноде) и
# отдаётся авторизованным GET-запросом на `/api/keygen` (поле
# `response.secretKey`) без каких-либо параметров. Для развёртывания через
# API (не руками через UI) это экономит шаг — не нужно идти в панель за
# значением, можно сразу подставить его в .env при создании ноды.
#
set -euo pipefail

PANEL_IP=""; NODE_PORT="2222"; SECRET_KEY=""
DIR="/opt/remnanode"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-ip)   PANEL_IP="$2"; shift 2 ;;
    --node-port)  NODE_PORT="$2"; shift 2 ;;
    --secret-key) SECRET_KEY="$2"; shift 2 ;;
    --dir)        DIR="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"
[[ -n "$PANEL_IP" ]] || die "Укажите --panel-ip"
command -v docker >/dev/null || die "Docker не установлен. Сначала прогоните 00-hardening.sh"

mkdir -p "$DIR"; cd "$DIR"

log "Создание .env"
cat > "$DIR/.env" <<EOF
### Порт, на котором нода слушает управляющие запросы от панели.
### Наружу быть открытым НЕ должен — только с IP панели.
### Обязан совпадать с портом, указанным при создании этой ноды в панели.
NODE_PORT=$NODE_PORT

### Скопируйте значение SECRET_KEY из сгенерированного панелью
### docker-compose.yml для этой ноды: Nodes → Management → нода →
### "Copy docker-compose.yml". Отдельного поля под него в UI нет —
### оно только внутри этого сгенерированного текста.
SECRET_KEY=${SECRET_KEY:-PASTE_SECRET_KEY_FROM_PANEL_HERE}
EOF
chmod 600 "$DIR/.env"

log "Создание docker-compose.yml"
cat > "$DIR/docker-compose.yml" <<'EOF'
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    env_file: .env
    volumes:
      # Проброс geoip/geosite: позволяет обновлять базы маршрутизации
      # без пересборки образа
      - ./xray-assets:/usr/local/share/xray
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
EOF

# ── geoip / geosite ────────────────────────────────────────────────────────
log "Загрузка geoip/geosite (нужны для правил маршрутизации)"
mkdir -p "$DIR/xray-assets"
for f in geoip.dat geosite.dat; do
  curl -fsSL -o "$DIR/xray-assets/$f" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" \
    && log "  $f загружен" \
    || warn "  не удалось загрузить $f"
done

cat > /usr/local/bin/update-xray-assets.sh <<EOF
#!/bin/bash
set -e
for f in geoip.dat geosite.dat; do
  curl -fsSL -o "$DIR/xray-assets/\$f.new" \\
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/\$f" &&
  mv "$DIR/xray-assets/\$f.new" "$DIR/xray-assets/\$f"
done
docker restart remnanode
EOF
chmod +x /usr/local/bin/update-xray-assets.sh
( crontab -l 2>/dev/null | grep -v update-xray-assets; echo "31 3 * * 1 /usr/local/bin/update-xray-assets.sh >> /var/log/xray-assets.log 2>&1" ) | crontab -

# ── Firewall ───────────────────────────────────────────────────────────────
log "Правило firewall: панель → нода"
ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel' || true

# ── Проверка, что порт ноды не торчит наружу ───────────────────────────────
if ufw status | grep -E "^${NODE_PORT}/tcp\s+ALLOW\s+Anywhere" >/dev/null 2>&1; then
  warn "ВНИМАНИЕ: порт $NODE_PORT открыт для всех. Закройте: ufw delete allow $NODE_PORT/tcp"
fi

if grep -q 'PASTE_SECRET_KEY_FROM_PANEL_HERE' "$DIR/.env"; then
  cat <<EOF

════════════════════════════════════════════════════════════════
  Нода подготовлена, но НЕ запущена
════════════════════════════════════════════════════════════════
  Осталось:
   1. В панели создайте ноду (если не создали) с портом $NODE_PORT,
      нажмите "Copy docker-compose.yml", возьмите оттуда SECRET_KEY
   2. Вставьте это значение в $DIR/.env
   3. cd $DIR && docker compose up -d && docker compose logs -f

  Каталог     : $DIR
  Порт ноды   : $NODE_PORT (только с $PANEL_IP)
  geo-базы    : $DIR/xray-assets, обновление по понедельникам в 03:31

  Для ВЫХОДНОЙ ноды дополнительно откройте 443 только с RU-ноды:
      ufw allow from <IP_RU_НОДЫ> to any port 443 proto tcp

  Для RU-ВХОДНОЙ ноды: 443 должен быть открыт публично,
  плюс запустите 30-selfsteal.sh
════════════════════════════════════════════════════════════════
EOF
else
  log "SECRET_KEY задан, запускаю"
  docker compose pull && docker compose up -d
  sleep 5
  docker compose ps
  log "Логи: docker compose -f $DIR/docker-compose.yml logs -f"
fi
