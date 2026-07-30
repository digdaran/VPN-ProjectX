#!/usr/bin/env bash
#
# 40-keygen.sh — генератор ключей Reality, shortId и путей XHTTP
#
# Генерирует полный набор параметров для одной ноды и печатает
# готовые фрагменты серверного и клиентского конфига.
#
#   bash 40-keygen.sh --name de --sni www.microsoft.com
#   bash 40-keygen.sh --name ru --sni vpn.example.ru --selfsteal
#
# Если порт 443 на сервере уже занят чем-то своим (например x-ui) —
# сосуществование через нестандартный транзитный порт:
#   bash 40-keygen.sh --name de --sni www.microsoft.com --port 8443
#
set -euo pipefail

NAME="node"; SNI="www.microsoft.com"; SELFSTEAL=0; COUNT_SID=3; PORT="443"

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME="$2"; shift 2 ;;
    --sni)       SNI="$2"; shift 2 ;;
    --selfsteal) SELFSTEAL=1; shift ;;
    --sids)      COUNT_SID="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ── Поиск xray ─────────────────────────────────────────────────────────────
XRAY=""
if command -v xray >/dev/null 2>&1; then
  XRAY="xray"
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
  XRAY="docker exec remnanode xray"
else
  die "Не найден xray. Установите бинарь или запустите на узле с контейнером remnanode.
     Разовый вариант:  docker run --rm teddysun/xray xray x25519"
fi

KEYS="$($XRAY x25519)"
PRIVATE_KEY="$(echo "$KEYS" | grep -iE 'private' | awk '{print $NF}')"
PUBLIC_KEY="$(echo  "$KEYS" | grep -iE 'public'  | awk '{print $NF}')"

[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "Не удалось распарсить вывод xray x25519:
$KEYS"

UUID="$($XRAY uuid 2>/dev/null | tr -d '\r' || cat /proc/sys/kernel/random/uuid)"

SIDS=()
for _ in $(seq 1 "$COUNT_SID"); do
  SIDS+=("$(openssl rand -hex 8)")
done
SIDS_JSON="$(printf '"%s", ' "${SIDS[@]}")"; SIDS_JSON="[${SIDS_JSON%, }]"

# Путь XHTTP: правдоподобный, как у настоящего CDN
PATHS=("/assets/media/stream" "/cdn/v3/segments" "/static/chunk/data" "/api/v2/content" "/_next/static/media")
XPATH="${PATHS[$((RANDOM % ${#PATHS[@]}))]}/$(openssl rand -hex 3)"

if [[ $SELFSTEAL -eq 1 ]]; then
  DEST="127.0.0.1:8443"
  DEST_NOTE="self-steal: локальный nginx с вашим сертификатом"
else
  DEST="${SNI}:443"
  DEST_NOTE="классический Reality: чужой SNI-донор"
fi

cat <<EOF

════════════════════════════════════════════════════════════════
  Ключи для ноды: $NAME
════════════════════════════════════════════════════════════════
  Private key : $PRIVATE_KEY
  Public key  : $PUBLIC_KEY
  UUID        : $UUID
  shortIds    : ${SIDS[*]}
  XHTTP path  : $XPATH
  SNI         : $SNI
  dest        : $DEST   ($DEST_NOTE)
  port        : $PORT$([[ "$PORT" != "443" ]] && echo '   (нестандартный — сверьте с xray-transit-outbound.json и firewall)')

────────────────────────────────────────────────────────────────
  СЕРВЕР (inbound)
────────────────────────────────────────────────────────────────
{
  "tag": "vless-xhttp-reality-$NAME",
  "listen": "0.0.0.0",
  "port": $PORT,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "$UUID", "email": "user@$NAME" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$DEST",
      "xver": 0,
      "serverNames": ["$SNI"],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": $SIDS_JSON
    },
    "xhttpSettings": {
      "host": "$SNI",
      "path": "$XPATH",
      "mode": "auto",
      "extra": { "xPaddingBytes": "100-1000" }
    }
  },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true }
}

────────────────────────────────────────────────────────────────
  КЛИЕНТ (outbound)
────────────────────────────────────────────────────────────────
{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$SNI",
      "port": $PORT,
      "users": [{ "id": "$UUID", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$SNI",
      "fingerprint": "firefox",
      "publicKey": "$PUBLIC_KEY",
      "shortId": "${SIDS[0]}",
      "spiderX": "/"
    },
    "xhttpSettings": {
      "host": "$SNI",
      "path": "$XPATH",
      "mode": "auto",
      "extra": {
        "xPaddingBytes": "100-1000",
        "xmux": { "maxConnections": "2-3", "maxConcurrency": 0,
                  "cMaxReuseTimes": "64-128", "hMaxRequestTimes": "800-900",
                  "hMaxReusableSecs": "1800-3000" }
      }
    }
  }
}

────────────────────────────────────────────────────────────────
  ССЫЛКА (для мобильных клиентов)
────────────────────────────────────────────────────────────────
vless://$UUID@$SNI:$PORT?type=xhttp&security=reality&sni=$SNI&fp=firefox&pbk=$PUBLIC_KEY&sid=${SIDS[0]}&path=$(printf '%s' "$XPATH" | sed 's|/|%2F|g')&mode=auto#${NAME^^}

════════════════════════════════════════════════════════════════
  Не забудьте:
   • fingerprint ОБЯЗАН быть firefox (не chrome — он в чёрном списке)
   • xmux.maxConnections=2-3 — держит TLS-соединения ниже порога
   • версии Xray на сервере и клиенте должны совпадать
════════════════════════════════════════════════════════════════
EOF
