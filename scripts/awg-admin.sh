#!/usr/bin/env bash
#
# awg-admin.sh — временный доступ к web UI wg-easy с ОДНОГО IP (того, с которого
# вы сейчас зашли по SSH), без SSH-туннеля. Ставится 70-awg.sh как
# /usr/local/sbin/awg-admin; запускать на AWG-сервере от root.
#
#   awg-admin                     # открыть для IP из $SSH_CLIENT на 60 мин
#   awg-admin --ip 203.0.113.7    # явный IP (обязателен, если зашли через jump)
#   awg-admin --ttl 2h --port 51821
#   awg-admin --status
#   awg-admin --close
#
# Как устроено:
#   - wg-easy слушает только 127.0.0.1 (Docker обходит ufw — публиковать наружу
#     через compose нельзя). Наружу торчит socat на хосте: TLS (самоподписанный
#     сертификат /etc/awg-admin/) → 127.0.0.1:<UI-порт>. Хостовый процесс
#     подчиняется ufw, плюс socat сам режет источник через range=.
#   - ufw: allow from <IP> to any port <порт> proto tcp, комментарий awg-admin,
#     вставляется ПЕРЕД чужим deny-all (режим сосуществования, как fw_allow).
#   - socat — transient-юнит systemd awg-admin.service с RuntimeMaxSec=<ttl>:
#     по истечении (или --close) ExecStopPost убирает правило ufw.
#   - Одновременно открыт максимум один IP: новый запуск закрывает старый доступ.
#   - /etc/awg-admin/awg-admin.conf (необязателен): JUMP_IPS="ip1 ip2" — адреса
#     jump-хостов; если $SSH_CLIENT — один из них, без --ip скрипт откажет.
#
set -euo pipefail

UNIT="awg-admin"
CONF_DIR="/etc/awg-admin"
CONF="$CONF_DIR/awg-admin.conf"
STATE="/run/awg-admin.state"
COMPOSE="/opt/awg/docker-compose.yml"
PASS_FILE="/root/awg-admin-password"
TAG="awg-admin"

PORT="51821"
TTL="60m"
IP=""
ACTION="open"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)      IP="$2"; shift 2 ;;
    --ttl)     TTL="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --status)  ACTION="status"; shift ;;
    --close)   ACTION="close"; shift ;;
    --cleanup) ACTION="cleanup"; shift ;;   # внутренний: ExecStopPost юнита
    -h|--help) usage ;;
    *) die "Неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускайте от root"

# ── ufw: удалить все наши правила (по комментарию), с конца, чтобы номера не съезжали
ufw_cleanup() {
  command -v ufw >/dev/null || return 0
  local nums n
  nums=$(ufw status numbered 2>/dev/null \
    | awk -v t="# $TAG" 'index($0,t){match($0,/\[ *[0-9]+\]/); s=substr($0,RSTART+1,RLENGTH-2); gsub(/ /,"",s); print s}' \
    | sort -rn)
  for n in $nums; do ufw --force delete "$n" >/dev/null || true; done
}

# Позиция чужого deny-all (v4 или v6) — наше правило должно стоять выше
deny_all_pos() {
  local v6="$1"
  if [[ $v6 -eq 1 ]]; then
    ufw status numbered 2>/dev/null \
      | awk '/^\[ *[0-9]+\] +Anywhere \(v6\) +DENY IN +Anywhere \(v6\) *$/{gsub(/[][ ]/,"",$1); print $1; exit}'
  else
    ufw status numbered 2>/dev/null \
      | awk '/^\[ *[0-9]+\] +Anywhere +DENY IN +Anywhere *$/{gsub(/[][ ]/,"",$1); print $1; exit}'
  fi
}

ufw_open() {
  local ip="$1" port="$2" v6="$3" pos
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw не активен — источник ограничивает только socat (range=)"
    return 0
  fi
  pos=$(deny_all_pos "$v6")
  if [[ -n "$pos" ]]; then
    ufw insert "$pos" allow from "$ip" to any port "$port" proto tcp comment "$TAG" >/dev/null \
      || ufw allow from "$ip" to any port "$port" proto tcp comment "$TAG" >/dev/null
  else
    ufw allow from "$ip" to any port "$port" proto tcp comment "$TAG" >/dev/null
  fi
}

do_close() {
  systemctl stop "$UNIT.service" 2>/dev/null || true
  systemctl reset-failed "$UNIT.service" 2>/dev/null || true
  ufw_cleanup
  rm -f "$STATE"
}

case "$ACTION" in
  cleanup) ufw_cleanup; rm -f "$STATE"; exit 0 ;;
  close)   do_close; ok "Доступ к админке закрыт"; exit 0 ;;
  status)
    if systemctl is-active --quiet "$UNIT.service" && [[ -f "$STATE" ]]; then
      # shellcheck disable=SC1090
      . "$STATE"
      ok "Открыто для $S_IP → https://$S_URLHOST:$S_PORT  (закроется $(date -d "@$S_EXPIRES" '+%F %T %Z'))"
    else
      echo "Доступ закрыт"
    fi
    ufw status 2>/dev/null | grep "# $TAG" || true
    exit 0 ;;
esac

# ── open ────────────────────────────────────────────────────────────────────
command -v socat   >/dev/null || die "Нет socat: apt-get install -y socat"
command -v openssl >/dev/null || die "Нет openssl"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || die "--port: 1024–65535"

# TTL → секунды: 90 (минуты), 90s, 45m/45min, 2h
case "$TTL" in
  *[!0-9smhin]*|"") die "--ttl: число с суффиксом s/m/h (например 30m, 2h)" ;;
esac
if   [[ "$TTL" =~ ^([0-9]+)$ ]];          then TTL_SEC=$(( BASH_REMATCH[1] * 60 ))
elif [[ "$TTL" =~ ^([0-9]+)s$ ]];         then TTL_SEC=${BASH_REMATCH[1]}
elif [[ "$TTL" =~ ^([0-9]+)(m|min)$ ]];   then TTL_SEC=$(( BASH_REMATCH[1] * 60 ))
elif [[ "$TTL" =~ ^([0-9]+)h$ ]];         then TTL_SEC=$(( BASH_REMATCH[1] * 3600 ))
else die "--ttl: число с суффиксом s/m/h (например 30m, 2h)"; fi
(( TTL_SEC >= 60 && TTL_SEC <= 86400 )) || die "--ttl: от 1 минуты до 24 часов"

# Локальный порт UI wg-easy — из compose (127.0.0.1:<порт>:51821/tcp)
UI_PORT=$(grep -oE '127\.0\.0\.1:[0-9]+:51821' "$COMPOSE" 2>/dev/null | head -1 | cut -d: -f2)
[[ -n "$UI_PORT" ]] || die "Не нашёл публикацию UI в $COMPOSE — wg-easy ставился не через 70-awg.sh?"

# IP клиента
FROM_SSH=0
if [[ -z "$IP" ]]; then
  IP="${SSH_CLIENT%% *}"
  [[ -n "$IP" ]] || die "Нет \$SSH_CLIENT (запуск не из SSH или через sudo -i) — укажите --ip <ваш IP>"
  FROM_SSH=1
fi
IP="${IP#::ffff:}"
JUMP_IPS=""
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
if [[ $FROM_SSH -eq 1 ]]; then
  for j in $JUMP_IPS; do
    [[ "$IP" == "$j" ]] && die "$IP — это jump-хост (JUMP_IPS в $CONF), а не ваш браузер. Укажите --ip <ваш IP>"
  done
fi

V6=0
if [[ "$IP" == *:* ]]; then
  V6=1
  python3 -c 'import ipaddress,sys; a=ipaddress.IPv6Address(sys.argv[1]); sys.exit(a.is_private or a.is_loopback or a.is_link_local)' "$IP" 2>/dev/null \
    || die "$IP — не публичный IPv6"
else
  python3 -c 'import ipaddress,sys; a=ipaddress.IPv4Address(sys.argv[1]); sys.exit(a.is_private or a.is_loopback or a.is_link_local)' "$IP" 2>/dev/null \
    || die "$IP — не публичный IPv4 (или не IP)"
fi

# Адрес сервера, на который придёт клиент (src маршрута к нему). Слушаем
# только его: на 0.0.0.0:<порт> socat конфликтовал бы с 127.0.0.1:<UI-порт> Docker.
if [[ $V6 -eq 1 ]]; then
  SRV=$(ip -6 route get "$IP" 2>/dev/null | grep -oP 'src \K\S+' | head -1)
  [[ -n "$SRV" ]] || die "У сервера нет IPv6-маршрута до $IP — зайдите по IPv4 или укажите --ip <IPv4>"
  LISTEN="OPENSSL-LISTEN:$PORT,pf=ip6,bind=[$SRV],range=[$IP]/128"
  URLHOST="[$SRV]"
else
  SRV=$(ip -4 route get "$IP" 2>/dev/null | grep -oP 'src \K\S+' | head -1)
  [[ -n "$SRV" ]] || die "Нет маршрута до $IP"
  LISTEN="OPENSSL-LISTEN:$PORT,pf=ip4,bind=$SRV,range=$IP/32"
  URLHOST="$SRV"
  if python3 -c 'import ipaddress,sys; sys.exit(not ipaddress.IPv4Address(sys.argv[1]).is_private)' "$SRV"; then
    warn "Адрес сервера $SRV приватный (NAT у хостера) — в ссылке подставьте внешний IP"
  fi
fi

# Самоподписанный сертификат (один раз)
install -d -m 700 "$CONF_DIR"
if [[ ! -s "$CONF_DIR/key.pem" || ! -s "$CONF_DIR/cert.pem" ]]; then
  log "Создаю самоподписанный сертификат в $CONF_DIR"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=awg-admin" -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" 2>/dev/null
  chmod 600 "$CONF_DIR/key.pem"
fi

# Один IP одновременно: закрыть предыдущий доступ
if systemctl is-active --quiet "$UNIT.service" || ufw status 2>/dev/null | grep -q "# $TAG"; then
  log "Закрываю предыдущий доступ"
  do_close
fi

# Занят ли порт кем-то кроме 127.0.0.1/::1 (там может сидеть сам wg-easy от Docker)
BUSY=$(ss -Hltnp "sport = :$PORT" | awk '$4 !~ /^(127\.0\.0\.1|\[::1\]):/' | head -1)
[[ -z "$BUSY" ]] || die "Порт $PORT уже занят: $BUSY"

log "ufw: allow $IP → $PORT/tcp"
ufw_open "$IP" "$PORT" "$V6"

SELF=$(readlink -f "$0")
log "Запускаю socat (TLS → 127.0.0.1:$UI_PORT) на $TTL"
systemd-run --quiet --collect --unit="$UNIT" \
  --description="wg-easy UI для $IP (awg-admin)" \
  -p RuntimeMaxSec="$TTL_SEC" \
  -p ExecStopPost="$SELF --cleanup" \
  socat "$LISTEN,reuseaddr,fork,cert=$CONF_DIR/cert.pem,key=$CONF_DIR/key.pem,verify=0" \
        "TCP4:127.0.0.1:$UI_PORT" \
  || { ufw_cleanup; die "systemd-run не запустил socat"; }

sleep 1
if ! systemctl is-active --quiet "$UNIT.service"; then
  journalctl -u "$UNIT" -n 20 --no-pager || true
  do_close
  die "socat не поднялся"
fi

EXPIRES=$(( $(date +%s) + TTL_SEC ))
cat > "$STATE" <<EOF
S_IP="$IP"
S_PORT="$PORT"
S_URLHOST="$URLHOST"
S_EXPIRES="$EXPIRES"
EOF

cat <<EOF

════════════════════════════════════════════════════════════════
  Админка wg-easy открыта для $IP
════════════════════════════════════════════════════════════════
  URL       : https://$URLHOST:$PORT
              (сертификат самоподписанный — браузер предупредит)
  Логин     : admin
  Пароль    : cat $PASS_FILE
  Закроется : $(date -d "@$EXPIRES" '+%F %T %Z')  (раньше — awg-admin --close)
════════════════════════════════════════════════════════════════
EOF
