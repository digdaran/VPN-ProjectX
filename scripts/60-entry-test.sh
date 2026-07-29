#!/usr/bin/env bash
#
# 60-entry-test.sh — проверка точек входа НА ОБЪЁМЕ, а не на рукопожатии
#
# ЗАПУСКАТЬ ИЗ РОССИИ, с домашнего и с мобильного интернета. Не с сервера.
#
# Зачем отдельный скрипт: механизм tcp 16-20 (l4-25) замораживает TCP-соединение
# ПОСЛЕ передачи ~14-34 КБ. Рукопожатие проходит, страничка открывается, ping
# отличный — а на первом же мегабайте всё встаёт. Обычная проверка "подключился,
# сайт открылся" такой узел объявит рабочим.
#
#   bash 60-entry-test.sh --hosts "vpn.example.ru:443 kz.example.ru:8443 de.example.ru:8443"
#   bash 60-entry-test.sh --proxy 127.0.0.1:10808          # через поднятый клиент
#
set -uo pipefail

HOSTS=""
PROXY=""
SIZES=(10000 50000 500000 5000000)   # 10 КБ, 50 КБ, 500 КБ, 5 МБ
TIMEOUT=25

log()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)   HOSTS="$2"; shift 2 ;;
    --proxy)   PROXY="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null || { echo "нужен curl" >&2; exit 1; }

human() { # байты → человекочитаемо
  local b=$1
  if   [[ $b -ge 1000000 ]]; then echo "$((b/1000000)) МБ"
  elif [[ $b -ge 1000 ]];    then echo "$((b/1000)) КБ"
  else echo "$b Б"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Тест 1. Доступность точек входа (рукопожатие)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$HOSTS" ]]; then
  log "Доступность точек входа (TCP + TLS)"
  echo "  Напоминание: успех здесь НИЧЕГО не доказывает — ограничение проявляется на объёме."
  echo
  for hp in $HOSTS; do
    host="${hp%%:*}"; port="${hp##*:}"; [[ "$port" == "$host" ]] && port=443

    t0=$(date +%s%N)
    if timeout "$TIMEOUT" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      t1=$(date +%s%N); tcp_ms=$(( (t1-t0)/1000000 ))

      tls=$(timeout "$TIMEOUT" curl -sS -o /dev/null \
              -w '%{time_appconnect}' --max-time "$TIMEOUT" \
              "https://$host:$port/" 2>/dev/null || echo "0")

      if [[ "$tls" == "0" || "$tls" == "0.000000" ]]; then
        warn "$hp — TCP есть (${tcp_ms} мс), TLS не завершился"
        echo "        Это сигнатура ЗАМОРОЗКИ: TCP проходит, TLS виснет."
      else
        ok "$hp — TCP ${tcp_ms} мс, TLS $(printf '%.0f' "$(echo "$tls * 1000" | bc -l 2>/dev/null || echo 0)") мс"
      fi
    else
      bad "$hp — TCP недоступен"
    fi
  done
  echo
fi

# ─────────────────────────────────────────────────────────────────────────────
# Тест 2. Порог tcp 16-20 — главный тест
# ─────────────────────────────────────────────────────────────────────────────
log "Порог объёма в одном TCP-соединении"
echo "  Скачиваем растущие объёмы. Если 10 КБ проходит, а 500 КБ виснет —"
echo "  это tcp 16-20 (l4-25), и прямой вход на этот узел непригоден."
echo

CURL_OPTS=(-sS -o /dev/null --max-time "$TIMEOUT")
[[ -n "$PROXY" ]] && CURL_OPTS+=(--socks5-hostname "$PROXY")

if [[ -n "$PROXY" ]]; then
  echo "  Через прокси: $PROXY"
else
  echo "  НАПРЯМУЮ (без прокси) — измеряем состояние вашего канала"
fi
echo

PREV_OK=1
for bytes in "${SIZES[@]}"; do
  url="https://speed.cloudflare.com/__down?bytes=$bytes"
  res=$(timeout $((TIMEOUT+5)) curl "${CURL_OPTS[@]}" \
        -w '%{http_code} %{size_download} %{speed_download} %{time_total}' \
        "$url" 2>/dev/null || echo "000 0 0 0")

  read -r code got speed total <<<"$res"
  label=$(human "$bytes")

  if [[ "$code" == "200" && "$got" -ge $((bytes * 9 / 10)) ]]; then
    kbps=$(printf '%.0f' "$(echo "$speed / 1024" | bc -l 2>/dev/null || echo 0)")
    ok "$label — получено, ${kbps} КБ/с"
    PREV_OK=1
  else
    if [[ $PREV_OK -eq 1 && $bytes -ge 50000 ]]; then
      bad "$label — ОБРЫВ (код $code, получено $got из $bytes)"
      echo "        ⚠️  Порог найден между $(human $((bytes/10))) и $label."
      echo "        Похоже на tcp 16-20. Прямой вход на зарубежные узлы"
      echo "        работать не будет; нужен промежуточный узел с белым IP."
    else
      bad "$label — не получено (код $code)"
    fi
    PREV_OK=0
  fi
done

echo
# ─────────────────────────────────────────────────────────────────────────────
# Тест 3. Реальная нагрузка через прокси
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$PROXY" ]]; then
  log "Устойчивость под длительной нагрузкой (20 МБ)"
  echo "  Заморозка часто наступает не сразу, а на второй-третьей сотне КБ."
  echo
  res=$(timeout 90 curl -sS -o /dev/null --socks5-hostname "$PROXY" \
        --max-time 90 \
        -w '%{http_code} %{size_download} %{speed_download}' \
        "https://speed.cloudflare.com/__down?bytes=20000000" 2>/dev/null || echo "000 0 0")
  read -r code got speed <<<"$res"
  if [[ "$code" == "200" && "$got" -ge 19000000 ]]; then
    mbps=$(printf '%.1f' "$(echo "$speed * 8 / 1000000" | bc -l 2>/dev/null || echo 0)")
    ok "20 МБ получено, ${mbps} Мбит/с — канал устойчив"
  else
    bad "20 МБ не получено (код $code, $(human "$got"))"
    echo "        Канал рвётся под нагрузкой. Для мессенджеров может хватать,"
    echo "        для видео и загрузок — нет."
  fi
  echo

  log "Выходной IP и геолокация"
  ipinfo=$(timeout 20 curl -sS --socks5-hostname "$PROXY" --max-time 20 \
           https://ipinfo.io/json 2>/dev/null || echo '{}')
  if command -v jq >/dev/null 2>&1 && [[ "$ipinfo" != "{}" ]]; then
    echo "$ipinfo" | jq -r '"  IP: \(.ip // "?")  \(.country // "?")  \(.org // "?")"'
  else
    echo "  $ipinfo" | head -c 300; echo
  fi
  echo
fi

cat <<'EOF'
─────────────────────────────────────────────────────────────────
 Как читать результат
─────────────────────────────────────────────────────────────────
  Все объёмы прошли
      Ограничение на этом канале не применяется. Прямой вход
      можно использовать полноценно.

  10 КБ прошло, 50-500 КБ оборвалось
      Классический tcp 16-20 (l4-25). Прямой вход на зарубежные
      узлы непригоден. Нужен промежуточный узел с белым IP —
      то есть ваша RU-нода. Так и задумано.

  TCP проходит, TLS виснет
      Либо июньский алгоритм (заморозка 120 сек — подождите
      2 минуты и повторите с другим SNI), либо узел лежит.

  Работает на домашнем, не работает на мобильном
      Норма. Ограничения внедрялись на мобильных сетях раньше
      и жёстче. Тестируйте на обоих.
─────────────────────────────────────────────────────────────────
 Дополнительно
─────────────────────────────────────────────────────────────────
  Профильные инструменты дают более детальную картину:
    dpi-ch       https://github.com/hyperion-cs/dpi-checkers
    dpi-detector https://github.com/Runnin4ik/dpi-detector

  Проверяйте подсети ВСЕХ своих узлов, включая российские
  и казахстанский — списки меняются.
EOF
