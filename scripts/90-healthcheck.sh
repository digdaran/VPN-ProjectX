#!/usr/bin/env bash
#
# 90-healthcheck.sh — проверка живости и TSPU-гигиены всей инфраструктуры
#
# Запускать с любого узла (лучше с панели) по cron раз в 10 минут.
#
#   bash 90-healthcheck.sh --config /opt/healthcheck.conf
#   bash 90-healthcheck.sh --config /opt/healthcheck.conf --notify
#
# Формат /opt/healthcheck.conf:
#   RU_DOMAIN="vpn.example.ru"
#   PANEL_URL="https://panel.example.com"
#   PANEL_TOKEN="..."
#   EXIT_HOSTS="fr.example.com de.example.com nl.example.com kz.example.com"
#   TG_BOT_TOKEN="..."
#   TG_CHAT_ID="..."
#
#   # Опционально: если узел, откуда запускается healthcheck, сам не может
#   # достучаться до api.telegram.org напрямую (например панель в РФ, и
#   # Telegram у вашего провайдера режется по SNI) — шлём через SSH-туннель
#   # (SOCKS5) на любой узел с нормальным доступом. Ключ должен быть добавлен
#   # в authorized_keys того узла с ограничением
#   # 'restrict,port-forwarding,permitopen="api.telegram.org:443"' — тогда
#   # им нельзя воспользоваться ни для чего, кроме проброса до Telegram.
#   TG_RELAY_HOST="fr.example.com"
#   TG_RELAY_KEY="/root/.ssh/tg_relay"
#
set -uo pipefail

CONFIG="/opt/healthcheck.conf"
NOTIFY=0
FAILURES=()
WARNINGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --notify) NOTIFY=1; shift ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$CONFIG" ]] || { echo "Нет файла конфигурации: $CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAILURES+=("$*"); }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; WARNINGS+=("$*"); }
head_() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

echo "═══ Healthcheck $(date -u '+%Y-%m-%d %H:%M:%S UTC') ═══"

# ── 1. Self-steal на RU-ноде ───────────────────────────────────────────────
head_ "RU-нода: self-steal и активное зондирование"
if [[ -n "${RU_DOMAIN:-}" ]]; then
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$RU_DOMAIN/" 2>/dev/null || echo 000)"
  if [[ "$CODE" == "200" || "$CODE" == "301" || "$CODE" == "302" ]]; then
    ok "Активное зондирование: HTTP $CODE — сервер отдаёт нормальный сайт"
  else
    bad "Активное зондирование вернуло '$CODE'. Ожидался 2xx/3xx. Self-steal сломан — вы уязвимы к слою 3 DPI."
  fi

  # Сертификат: срок и издатель
  CERT_INFO="$(echo | timeout 15 openssl s_client -servername "$RU_DOMAIN" -connect "$RU_DOMAIN:443" 2>/dev/null | openssl x509 -noout -issuer -subject -enddate 2>/dev/null || true)"
  if [[ -n "$CERT_INFO" ]]; then
    ENDDATE="$(echo "$CERT_INFO" | grep notAfter | cut -d= -f2-)"
    if [[ -n "$ENDDATE" ]]; then
      END_TS="$(date -d "$ENDDATE" +%s 2>/dev/null || echo 0)"
      NOW_TS="$(date +%s)"
      DAYS=$(( (END_TS - NOW_TS) / 86400 ))
      if   [[ $DAYS -lt 0  ]]; then bad  "Сертификат ПРОСРОЧЕН"
      elif [[ $DAYS -lt 10 ]]; then warn "Сертификат истекает через $DAYS дн. — проверьте certbot.timer"
      else ok "Сертификат действителен ещё $DAYS дн."
      fi
    fi
    # Проверка, что CN совпадает с доменом — иначе несоответствие SNI/сертификата
    if echo "$CERT_INFO" | grep -q "CN *= *$RU_DOMAIN"; then
      ok "CN сертификата совпадает с доменом (self-steal целостен)"
    else
      warn "CN сертификата не совпадает с $RU_DOMAIN — проверьте, тот ли сертификат отдаётся"
    fi
  else
    bad "Не удалось получить сертификат с $RU_DOMAIN:443"
  fi

  # DNS должен указывать на тот же IP — иначе self-steal ломается
  RESOLVED="$(dig +short A "$RU_DOMAIN" @1.1.1.1 2>/dev/null | tail -1)"
  [[ -n "$RESOLVED" ]] && ok "DNS: $RU_DOMAIN → $RESOLVED" || bad "DNS не резолвит $RU_DOMAIN"
else
  warn "RU_DOMAIN не задан — проверка пропущена"
fi

# ── 2. Выходные ноды ───────────────────────────────────────────────────────
head_ "Выходные ноды: доступность порта 443"
for host in ${EXIT_HOSTS:-}; do
  if timeout 8 bash -c "</dev/tcp/$host/443" 2>/dev/null; then
    RTT="$(ping -c 2 -W 2 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')"
    ok "$host — порт 443 открыт${RTT:+, RTT ${RTT} ms}"
  else
    # Это может быть НОРМОЙ: если firewall пускает только RU-ноду,
    # с панели порт будет закрыт. Проверяйте с RU-ноды.
    warn "$host — порт 443 недоступен отсюда (норма, если firewall пускает только RU-ноду)"
  fi
done

# ── 3. Панель и ноды через API ─────────────────────────────────────────────
head_ "Панель Remnawave"
if [[ -n "${PANEL_URL:-}" && -n "${PANEL_TOKEN:-}" ]]; then
  RESP="$(curl -sS --max-time 15 -H "Authorization: Bearer $PANEL_TOKEN" "$PANEL_URL/api/nodes" 2>/dev/null || true)"
  if echo "$RESP" | jq -e '.response' >/dev/null 2>&1; then
    ok "API панели отвечает"
    echo "$RESP" | jq -r '.response[] | "\(.name)\t\(.isConnected)\t\(.isDisabled)\t\(.versions.xray // "?")"' 2>/dev/null |
    while IFS=$'\t' read -r name conn disabled ver; do
      if [[ "$disabled" == "true" ]]; then
        printf '  \033[1;33m!\033[0m нода %s — отключена вручную\n' "$name"
      elif [[ "$conn" == "true" ]]; then
        printf '  \033[1;32m✓\033[0m нода %s — подключена (xray %s)\n' "$name" "$ver"
      else
        printf '  \033[1;31m✗\033[0m нода %s — НЕ ПОДКЛЮЧЕНА\n' "$name"
      fi
    done

    # Версии Xray должны совпадать на всех нодах: рассинхрон ломает XHTTP
    VERS="$(echo "$RESP" | jq -r '[.response[] | select(.isConnected==true) | .versions.xray] | unique | join(", ")' 2>/dev/null)"
    NVER="$(echo "$RESP" | jq -r '[.response[] | select(.isConnected==true) | .versions.xray] | unique | length' 2>/dev/null)"
    if [[ "${NVER:-0}" -gt 1 ]]; then
      bad "РАЗНЫЕ версии Xray на нодах: $VERS. XHTTP в активной разработке — рассинхрон даёт молчаливые сбои."
    elif [[ "${NVER:-0}" -eq 1 ]]; then
      ok "Версия Xray едина на всех нодах: $VERS"
    fi

    # Число подключённых нод
    NDOWN="$(echo "$RESP" | jq -r '[.response[] | select(.isConnected==false and .isDisabled==false)] | length' 2>/dev/null)"
    [[ "${NDOWN:-0}" -gt 0 ]] && bad "Нод не на связи: $NDOWN"
  else
    bad "API панели не отвечает или токен невалиден"
  fi
else
  warn "PANEL_URL/PANEL_TOKEN не заданы — проверка пропущена"
fi

# ── 4. Локальные ресурсы ───────────────────────────────────────────────────
head_ "Ресурсы локального узла"
DISK="$(df -h / | awk 'NR==2{print $5}' | tr -d '%')"
[[ "$DISK" -gt 85 ]] && bad "Диск заполнен на ${DISK}%" || ok "Диск: ${DISK}%"

MEM="$(free | awk '/Mem:/{printf "%.0f", $3/$2*100}')"
[[ "$MEM" -gt 90 ]] && warn "Память: ${MEM}%" || ok "Память: ${MEM}%"

CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
[[ "$CC" == "bbr" ]] && ok "Congestion control: bbr" || warn "Congestion control: $CC (ожидался bbr)"

if command -v docker >/dev/null 2>&1; then
  UNHEALTHY="$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
  [[ -n "$UNHEALTHY" ]] && bad "Нездоровые контейнеры: $UNHEALTHY" || ok "Контейнеры в порядке"
fi

# ── 5. Гигиена белого IP ───────────────────────────────────────────────────
head_ "Гигиена белого IP"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ok "ufw активен"
  ufw status 2>/dev/null | grep -q '25/tcp.*DENY OUT' \
    && ok "Исходящий SMTP заблокирован" \
    || warn "Исходящий SMTP НЕ заблокирован — риск спам-абуз и потери IP"
else
  warn "ufw неактивен"
fi

# ── Итог ───────────────────────────────────────────────────────────────────
echo
if [[ ${#FAILURES[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
  echo "═══ Всё в порядке ═══"
  STATUS_LINE="✅ Инфраструктура в норме"
  EXIT_CODE=0
else
  echo "═══ Проблем: ${#FAILURES[@]}, предупреждений: ${#WARNINGS[@]} ═══"
  STATUS_LINE="⚠️ Проблем: ${#FAILURES[@]}, предупреждений: ${#WARNINGS[@]}"
  for f in "${FAILURES[@]}";  do echo "  ✗ $f"; STATUS_LINE="$STATUS_LINE"$'\n'"✗ $f"; done
  for w in "${WARNINGS[@]}";  do echo "  ! $w"; done
  EXIT_CODE=1
fi

# ── Уведомление в Telegram ─────────────────────────────────────────────────
if [[ $NOTIFY -eq 1 && ${#FAILURES[@]} -gt 0 && -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
  if [[ -n "${TG_RELAY_HOST:-}" ]]; then
    # Telegram недоступен напрямую (узел в РФ и т.п.) — временный SOCKS5
    # через ограниченный ключ, только на время отправки одного сообщения.
    RELAY_KEY="${TG_RELAY_KEY:-/root/.ssh/tg_relay}"
    RELAY_PORT=$(( (RANDOM % 5000) + 20000 ))
    ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
        -i "$RELAY_KEY" -D "$RELAY_PORT" -N "root@$TG_RELAY_HOST" &
    RELAY_PID=$!
    sleep 2
    curl -sS --max-time 15 -X POST --socks5-hostname "127.0.0.1:$RELAY_PORT" \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=$STATUS_LINE" >/dev/null && echo "Уведомление отправлено (через $TG_RELAY_HOST)"
    kill "$RELAY_PID" 2>/dev/null
  else
    curl -sS --max-time 15 -X POST \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=$STATUS_LINE" >/dev/null && echo "Уведомление отправлено"
  fi
fi

exit $EXIT_CODE
