#!/bin/sh
# router-diag.sh — диагностика доступности Xray-нод С РОУТЕРА (контейнер mihomo-mikrotik, busybox sh)
#
#   1. Загрузить файл в <mount>/etc/  (у Tavrida: usb1-part1/docker/mihomo/etc/router-diag.sh)
#   2. /container shell Mihomo-Mikrotik
#   3. sh /etc/mihomo/router-diag.sh            (≈2 мин; вывод прислать целиком)
#
# Ничего не меняет, секретов не печатает. Вывод только ASCII — терминал
# RouterOS съедает кириллицу/эмодзи. Список нод — на 2026-11-08.

API="http://127.0.0.1:9090"
AUTH=""; [ -n "$UI_SECRET" ] && AUTH="Authorization: Bearer $UI_SECRET"
URL204="https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"

NODES="Finland|vfin.08u.ru|109.69.61.12
Finland2|vfin2.08u.ru|135.136.177.114
Kazakhstan|vkz.08u.ru|206.223.247.6
France|131.123.36.11|131.123.36.11
Germany|103.244.227.56|103.244.227.56
Moldova|80.96.113.152|80.96.113.152
Austria|vau.08u.ru|85.192.27.243"

tcp()   { timeout 7 nc -z -w 6 "$1" "$2" >/dev/null 2>&1 && echo "ok  " || echo "FAIL"; }
ascii() { LC_ALL=C tr -cd '\11\12\40-\176' | sed 's/^ *//'; }
urlenc(){ printf %s "$1" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g'; }
api()   { wget -qO- ${AUTH:+--header "$AUTH"} "$API$1" 2>&1; }

echo "=== router-diag v2 $(date -u '+%F %T') UTC | mihomo $(mihomo -v 2>/dev/null | head -1 | awk '{print $3}') ==="
echo "--- control (expect ok): ya.ru:443 $(tcp ya.ru 443) | 1.1.1.1:443 $(tcp 1.1.1.1 443)"

echo "--- DNS: system / 8.8.8.8 / 77.88.8.8 (must equal 'want')"
echo "$NODES" | while IFS='|' read n host want; do
  case "$host" in *[a-z]*) ;; *) continue ;; esac
  r() { nslookup "$host" $1 2>/dev/null | awk '/^Address/ && !/#53/ {print $NF}' | grep -E '^[0-9.]+$' | head -1; }
  s=$(r); g=$(r 8.8.8.8); y=$(r 77.88.8.8); flag=""
  for x in "$s" "$g" "$y"; do [ "$x" = "$want" ] || flag="  <-- MISMATCH"; done
  printf "  %-13s want %-16s sys %-16s g %-16s y %-16s%s\n" "$host" "$want" "${s:--}" "${g:--}" "${y:--}" "$flag"
done

echo "--- TCP by IP: 443 (Direct) / 2087 (Stream-Up)"
echo "$NODES" | while IFS='|' read n host ip; do
  printf "  %-11s %-16s 443:%s 2087:%s\n" "$n" "$ip" "$(tcp $ip 443)" "$(tcp $ip 2087)"
done

echo "--- groups now:"
for g in SELECTOR AUTO FASTEST FAILOVER AWG_FAILOVER; do
  printf "  %-13s -> %s\n" "$g" "$(api /proxies/$g | sed -n 's/.*"now":"\([^"]*\)".*/\1/p' | ascii)"
done

echo "--- mihomo delay per proxy, 2 tries, 8s: ms | TIMEOUT=no reply | ERROR(503)=reset/refused/TLS fail"
for prov in SUB1 AWG; do
  api /providers/proxies/$prov | grep -o '"name":"[^"]*"' | sed 's/"name":"//; s/"$//' | grep -vx "$prov" | sed "s/^/$prov|/"
done | awk '!seen[$0]++' > /tmp/.px
while IFS='|' read -r prov p; do
  e=$(urlenc "$p"); res=""
  for i in 1 2; do
    r=$(api "/providers/proxies/$prov/$e/healthcheck?url=$URL204&timeout=8000")
    d=$(echo "$r" | sed -n 's/.*"delay":\([0-9]*\).*/\1/p')
    if [ -n "$d" ]; then res="$res ${d}ms"
    else c=$(echo "$r" | grep -oE 'HTTP/1.1 [0-9]{3}' | awk '{print $2}')
      case "$c" in 504) res="$res TIMEOUT";; 503) res="$res ERROR(503)";; *) res="$res ERR(${c:-?})";; esac; fi
  done
  printf "  %-34s%s\n" "$(echo "$p" | ascii)" "$res"
done < /tmp/.px
rm -f /tmp/.px
echo "=== end ==="
