#!/usr/bin/env bash
#
# 50-preflight.sh — проверка, что в конфигах не осталось незаменённых
# плейсхолдеров, и что критичные анти-ТСПУ параметры на месте.
#
# Запускать перед выкаткой:
#   bash 50-preflight.sh /path/to/config.json
#
set -uo pipefail

FILES=("$@")
[[ ${#FILES[@]} -eq 0 ]] && FILES=(configs/*.json configs/ready/*.json)

FAIL=0
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=1; }

PLACEHOLDERS='PRIVATE_KEY|PUBLIC_KEY|TRANSIT_UUID|SHORT_ID_|PASTE_|example\.(ru|com)|00000000-0000-0000'

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  echo "▸ $f"

  # 1. Валидный JSON
  if python3 -c "import json;json.load(open('$f'))" 2>/dev/null; then
    ok "валидный JSON"
  else
    bad "невалидный JSON"; continue
  fi

  # 2. Незаменённые плейсхолдеры
  if hits=$(grep -oE "$PLACEHOLDERS" "$f" | sort -u | tr '\n' ' '); [[ -n "$hits" ]]; then
    bad "остались плейсхолдеры: $hits"
  else
    ok "плейсхолдеров не осталось"
  fi

  # 3. fingerprint не из чёрного списка
  if grep -qE '"fingerprint"\s*:\s*"(chrome|safari|ios|random)"' "$f"; then
    bad "fingerprint из чёрного списка (нужен firefox/edge)"
  elif grep -q '"fingerprint"' "$f"; then
    ok "fingerprint допустимый"
  fi

  # 4. xmux: maxConnections без maxConcurrency=0 не работает
  if grep -q 'maxConnections' "$f"; then
    if python3 - "$f" <<'PY'
import json,sys
def walk(o):
    if isinstance(o,dict):
        yield o
        for v in o.values(): yield from walk(v)
    elif isinstance(o,list):
        for v in o: yield from walk(v)
bad=False
for n in walk(json.load(open(sys.argv[1]))):
    x=n.get("xmux")
    if isinstance(x,dict) and "maxConnections" in x and x.get("maxConcurrency")!=0:
        bad=True
sys.exit(1 if bad else 0)
PY
    then ok "xmux корректен (maxConcurrency=0)"
    else bad "xmux: при заданном maxConnections требуется maxConcurrency=0"
    fi
  fi

  # 5. Защита белого IP в routing
  if grep -q '"routing"' "$f"; then
    grep -q 'bittorrent' "$f" && ok "торренты заблокированы" || bad "НЕТ блокировки торрентов"
    grep -q 'geoip:private' "$f" && ok "приватные сети заблокированы" || bad "НЕТ блокировки geoip:private"
  fi
  echo
done

[[ $FAIL -eq 0 ]] && echo "Готово к выкатке." || echo "Есть проблемы — исправьте перед выкаткой."
exit $FAIL
