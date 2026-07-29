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
  # encoding='utf-8' обязателен: на Windows open() иначе берёт системную
  # кодировку (cp1251 и т.п.), а в _comment встречается кириллица.
  if python3 -c "import json;json.load(open('$f', encoding='utf-8'))" 2>/dev/null; then
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
for n in walk(json.load(open(sys.argv[1], encoding="utf-8"))):
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

# 6. Кросс-проверка: transit-in выходной ноды должен совпадать с "своим"
# out-* в xray-transit-outbound.json (serverName + xhttpSettings.host/path).
# Ловит ситуацию, когда xray-exit-node(-public).json скопировали на FR/NL/KZ
# ноду, но забыли поменять SNI-донор под конкретную страну — по отдельности
# оба файла валидны, рукопожатие Reality между ними просто не установится.
echo "▸ кросс-проверка: exit-node transit-in <-> xray-transit-outbound.json"
if python3 - "${FILES[@]}" <<'PY'
import json, sys

sys.stdout.reconfigure(encoding="utf-8")  # иначе на Windows-консоли (cp1251) валится на ✓/✗

transit_legs = []      # (file, tag, serverName, host, path) — клиентская сторона (RU-нода)
exit_transit_in = []    # (file, serverName, host, path)      — серверная сторона (выходная нода)

for fn in sys.argv[1:]:
    try:
        data = json.load(open(fn, encoding="utf-8"))
    except Exception:
        continue

    for ob in data.get("outbounds", []) or []:
        tag = ob.get("tag", "")
        if not tag.startswith("out-"):
            continue
        ss = ob.get("streamSettings") or {}
        rs = ss.get("realitySettings") or {}
        xs = ss.get("xhttpSettings") or {}
        sn, host, path = rs.get("serverName"), xs.get("host"), xs.get("path")
        if sn and host and path:
            transit_legs.append((fn, tag, sn, host, path))

    for ib in data.get("inbounds", []) or []:
        if ib.get("tag") != "transit-in":
            continue
        ss = ib.get("streamSettings") or {}
        rs = ss.get("realitySettings") or {}
        xs = ss.get("xhttpSettings") or {}
        names = rs.get("serverNames") or []
        sn = names[0] if names else None
        host, path = xs.get("host"), xs.get("path")
        if sn and host and path:
            exit_transit_in.append((fn, sn, host, path))

if not transit_legs or not exit_transit_in:
    print("  (пропущено: нет пары exit-node + xray-transit-outbound.json среди проверяемых файлов)")
    sys.exit(0)

ok = True
for fn, sn, host, path in exit_transit_in:
    match = next((t for t in transit_legs if t[2:] == (sn, host, path)), None)
    if match:
        print(f"  \033[1;32m✓\033[0m {fn}: совпадает с {match[1]} ({match[0]})")
    else:
        ok = False
        sources = ", ".join(sorted({t[0] for t in transit_legs}))
        print(f"  \033[1;31m✗\033[0m {fn}: transit-in (sni={sn}, host={host}, path={path}) "
              f"не совпадает НИ С ОДНИМ out-* в {sources} — Reality-рукопожатие сломается")

sys.exit(0 if ok else 1)
PY
then
  :
else
  FAIL=1
fi
echo

[[ $FAIL -eq 0 ]] && echo "Готово к выкатке." || echo "Есть проблемы — исправьте перед выкаткой."
exit $FAIL
