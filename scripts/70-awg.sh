#!/usr/bin/env bash
#
# 70-awg.sh — независимый AmneziaWG-контур на wg-easy (ADR-0008, уровень E)
#
# Запускать ПОСЛЕ 00-hardening.sh --role awg --awg-port <PORT>:
#   sudo bash 70-awg.sh --port 47321 --host cdn-xx.example.com
#
# Что делает:
#   - поднимает wg-easy (версия закреплена) с AmneziaWG 3.1 в docker compose;
#   - AWG принудительно (OVERRIDE_AUTO_AWG=awg): без этого при отсутствии
#     модуля ядра wg-easy МОЛЧА откатывается на обычный WireGuard, который
#     DPI ловит по рукопожатию;
#   - если модуля ядра amneziawg нет (на свежих ядрах DKMS часто не собирается),
#     работает userspace amneziawg-go из образа — нужен /dev/net/tun;
#   - web UI публикуется ТОЛЬКО на 127.0.0.1 (Docker обходит ufw!), доступ —
#     через SSH-туннель: ssh -p <ssh> -L 51821:127.0.0.1:51821 root@<сервер>;
#     либо временно с одного IP — awg-admin (scripts/awg-admin.sh, ставится здесь);
#   - пароль админа генерируется и кладётся в /root/awg-admin-password (600),
#     после первого старта INIT_PASSWORD из .env удаляется.
#
# Клиенты: AmneziaWG/Amnezia VPN (3.x), Mihomo >= 1.19.30 с amnezia-wg-option
# version: 3 (см. docs/awg.md). Клиенты AWG 2.x с параметрами 3.x НЕ работают.
#
set -euo pipefail

WG_EASY_IMAGE="ghcr.io/wg-easy/wg-easy:15.5.0"
DIR="/opt/awg"
PORT=""
HOST=""
UI_PORT="51821"
DNS="1.1.1.1,9.9.9.9"
IPV4_CIDR="10.8.0.0/24"
IPV6_CIDR="fdcc:ad94:bacf:61a4::cafe:0/112"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    PORT="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    --ui-port) UI_PORT="$2"; shift 2 ;;
    --dns)     DNS="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "Укажите --port (тот же, что в 00-hardening.sh --awg-port)"
[[ -n "$HOST" ]] || die "Укажите --host: домен (предпочтительно — при блоке IP меняется только A-запись) или IP"
command -v docker >/dev/null || die "Нет docker — сначала 00-hardening.sh"
[[ -c /dev/net/tun ]] || die "Нет /dev/net/tun — userspace amneziawg-go не запустится"
ufw status | grep -qE "^$PORT/udp +ALLOW" || warn "В ufw нет правила для $PORT/udp — клиенты не подключатся (00-hardening.sh --role awg --awg-port $PORT)"

# ── Блок BitTorrent из AWG-подсети ─────────────────────────────────────────
# Xray-ноды режут торренты сами (routing: protocol bittorrent → block), а AWG —
# голый L3-туннель: без этого торренты клиентов уходят с IP сервера → жалобы
# правообладателей хостеру → потеря IP. Фильтр в DOCKER-USER (Docker её не трогает),
# только первые 20 пакетов соединения (connbytes) — дёшево для 1 vCPU.
# Ограничение: шифрованный BT (MSE/PE) и чистый uTP по сигнатуре не ловятся.
# Вызов install_p2p_block — ниже, после старта контейнера (нужна сеть awg_awg).
P2P_V4_SUBNET="172.30.233.0/24"
P2P_V6_SUBNET="fd00:a3c0:233::/64"
install_p2p_block() {
  log "Блок BitTorrent для клиентов AWG (DOCKER-USER → AWG-P2P)"
  cat > /usr/local/sbin/awg-p2p-block.sh <<EOF
#!/usr/bin/env bash
# Генерируется 70-awg.sh. Идемпотентен: пересоздаёт цепочку AWG-P2P.
set -euo pipefail
modprobe xt_string 2>/dev/null || true
for ipt in iptables ip6tables; do
  if [[ \$ipt == iptables ]]; then SUB="$P2P_V4_SUBNET"; else SUB="$P2P_V6_SUBNET"; fi
  \$ipt -N DOCKER-USER 2>/dev/null || true
  \$ipt -N AWG-P2P 2>/dev/null || \$ipt -F AWG-P2P
  while \$ipt -D DOCKER-USER -s "\$SUB" -j AWG-P2P 2>/dev/null; do :; done
  \$ipt -I DOCKER-USER 1 -s "\$SUB" -j AWG-P2P
  EARLY="-m connbytes --connbytes 0:20 --connbytes-dir both --connbytes-mode packets"
  for proto in tcp udp; do
    \$ipt -A AWG-P2P -p \$proto \$EARLY -m string --algo bm --string "BitTorrent protocol" -j DROP
  done
  for s in "d1:ad2:id20:" "d1:rd2:id20:" "get_peers" "announce_peer"; do   # DHT (KRPC)
    \$ipt -A AWG-P2P -p udp \$EARLY -m string --algo bm --string "\$s" -j DROP
  done
  \$ipt -A AWG-P2P -p udp \$EARLY -m string --algo bm --hex-string "|0000041727101980|" -j DROP   # UDP-трекер connect
  for s in "info_hash=" "peer_id="; do                                       # HTTP-трекер announce
    \$ipt -A AWG-P2P -p tcp \$EARLY -m string --algo bm --string "\$s" -j DROP
  done
  \$ipt -A AWG-P2P -j RETURN
done
EOF
  chmod 755 /usr/local/sbin/awg-p2p-block.sh
  cat > /etc/systemd/system/awg-p2p-block.service <<'EOF'
[Unit]
Description=Block BitTorrent from AmneziaWG clients (DOCKER-USER/AWG-P2P)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/awg-p2p-block.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now awg-p2p-block.service >/dev/null
  systemctl restart awg-p2p-block.service
  ok "BitTorrent из AWG-подсети блокируется (счётчики: iptables -L AWG-P2P -v -n)"
}

if [[ -f "$DIR/docker-compose.yml" ]]; then
  die "$DIR уже развёрнут. Повторный INIT ничего не сделает (wg-easy применяет INIT_* только при первом старте). Удалите $DIR и volume awg_etc_wireguard, если нужна переустановка."
fi

if lsmod | grep -q '^amneziawg'; then
  log "Модуль ядра amneziawg загружен — будет kernel-режим"
else
  warn "Модуля ядра amneziawg нет — будет userspace amneziawg-go (нормально для десятков клиентов)"
fi

mkdir -p "$DIR"; chmod 700 "$DIR"
PASS_FILE=/root/awg-admin-password
if [[ ! -s $PASS_FILE ]]; then
  ( umask 077; openssl rand -base64 24 | tr -d '/+=' | head -c 24 > "$PASS_FILE" )
fi

log "Пишу $DIR/.env и docker-compose.yml"
( umask 077; cat > "$DIR/.env" <<EOF
INIT_ENABLED=true
INIT_USERNAME=admin
INIT_PASSWORD=$(cat "$PASS_FILE")
INIT_HOST=$HOST
INIT_PORT=$PORT
INIT_DNS=$DNS
INIT_IPV4_CIDR=$IPV4_CIDR
INIT_IPV6_CIDR=$IPV6_CIDR
INIT_ALLOWED_IPS=0.0.0.0/0,::/0
EOF
)

cat > "$DIR/docker-compose.yml" <<EOF
services:
  wg-easy:
    image: $WG_EASY_IMAGE
    container_name: wg-easy
    restart: unless-stopped
    env_file: .env
    environment:
      - EXPERIMENTAL_AWG=true
      - OVERRIDE_AUTO_AWG=awg      # не откатываться молча на обычный WireGuard
      - INSECURE=true              # http разрешён: UI доступен только с 127.0.0.1 (SSH-туннель)
      - DISABLE_VERSION_CHECK=true
    ports:
      - "$PORT:$PORT/udp"
      - "127.0.0.1:$UI_PORT:51821/tcp"
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
    networks:
      - awg
# IPv6 в сети Docker по умолчанию ВЫКЛЮЧЕН: без этого клиентский ::/0 уходит
# в туннель и пропадает (приложения, пробующие сначала IPv6, подвисают).
# ULA-подсеть — Docker сам делает для неё NAT (ip6tables masquerade).
networks:
  awg:
    enable_ipv6: true
    ipam:
      config:
        - subnet: 172.30.233.0/24
        - subnet: fd00:a3c0:233::/64
volumes:
  etc_wireguard:
EOF

log "Запуск wg-easy ($WG_EASY_IMAGE)"
cd "$DIR"
docker compose pull -q
docker compose up -d

log "Жду поднятия интерфейса"
for _ in $(seq 1 30); do
  docker exec wg-easy sh -c 'awg show 2>/dev/null | grep -q "listening port"' && break
  sleep 2
done
docker exec wg-easy sh -c 'awg show 2>/dev/null | grep -q "listening port"' \
  || { docker logs --tail 40 wg-easy; die "AWG-интерфейс не поднялся"; }

# Проверяем, что это действительно AWG, а не голый WireGuard
JC=$(docker exec wg-easy sh -c "awg showconf \$(awg show interfaces | head -1) 2>/dev/null | awk -F' = ' 'tolower(\$1)==\"jc\"{print \$2}'")
[[ -n "$JC" && "$JC" != "0" ]] && ok "Обфускация AWG активна (Jc=$JC)" \
  || warn "В конфиге интерфейса нет Jc — похоже на обычный WireGuard! Проверьте: docker exec wg-easy awg showconf wg0"
docker exec wg-easy sh -c "awg showconf \$(awg show interfaces | head -1)" | grep -qiE '^headerprotectionkey' \
  && ok "HeaderProtectionKey задан — режим AWG 3.x (клиенты только 3.x / Mihomo version: 3)" \
  || warn "HeaderProtectionKey не задан — режим совместимости 2.x. Для 3.x задайте параметры в UI (Admin → AmneziaWG)"

install_p2p_block

# ── awg-admin: временный доступ к UI с одного IP без SSH-туннеля ──────────
log "Ставлю awg-admin (временный доступ к UI с IP текущей SSH-сессии)"
command -v socat >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat >/dev/null; }
install -m 755 "$(dirname "$(readlink -f "$0")")/awg-admin.sh" /usr/local/sbin/awg-admin
ok "awg-admin установлен: awg-admin [--ip IP] [--ttl 60m] | --status | --close"

log "Убираю INIT_PASSWORD из .env (пароль — в $PASS_FILE)"
sed -i '/^INIT_PASSWORD=/d' "$DIR/.env"

cat <<EOF

════════════════════════════════════════════════════════════════
  AmneziaWG (wg-easy) запущен
════════════════════════════════════════════════════════════════
  Endpoint        : $HOST:$PORT/udp
  Web UI          : только через SSH-туннель:
                    ssh -p <ssh-порт> -L $UI_PORT:127.0.0.1:$UI_PORT root@<сервер>
                    → http://127.0.0.1:$UI_PORT  (admin / пароль в $PASS_FILE)
                    или без туннеля, с IP текущей SSH-сессии: awg-admin (docs/awg.md)
  Режим           : $(lsmod | grep -q '^amneziawg' && echo 'kernel amneziawg' || echo 'userspace amneziawg-go')

  Дальше:
    1. Войти в UI, включить 2FA (Account → 2FA).
    2. Создать по клиенту на роутер/устройство, скачать .conf.
    3. Для Mihomo перенести параметры в amnezia-wg-option (docs/awg.md).
════════════════════════════════════════════════════════════════
EOF
