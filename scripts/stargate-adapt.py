#!/usr/bin/env python3
"""
stargate-adapt.py — адаптирует шаблон Stargate (Viktor45/mh-templates) под VPN-ProjectX

    python3 scripts/stargate-adapt.py [upstream.yaml] [out.yaml]

Без аргументов скачивает актуальный stargate.yaml с GitHub и пишет
stargate-tavrida.yaml в корень проекта. Каждая правка обязана найти своё место
РОВНО один раз — если upstream поменялся, скрипт падает с понятной ошибкой,
а не выдаёт молча «полуадаптированный» шаблон.

Что меняется и зачем — см. HEADER ниже (он же попадает в итоговый файл) и docs/awg.md.
"""
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

UPSTREAM_URL = "https://raw.githubusercontent.com/Viktor45/mh-templates/refs/heads/main/stargate.yaml"
COMMITS_API = "https://api.github.com/repos/Viktor45/mh-templates/commits?path=stargate.yaml&per_page=1"
ROOT = Path(__file__).resolve().parent.parent


def upstream_commit() -> str:
    try:
        import json
        with urllib.request.urlopen(COMMITS_API, timeout=15) as r:
            c = json.load(r)[0]
        return f"{c['sha'][:8]} ({c['commit']['author']['date'][:10]})"
    except Exception:
        return "неизвестен"


HEADER = """# ============================================================================
# STARGATE — адаптация VPN-ProjectX для роутеров Tavrida (MikroTik + mihomo-mikrotik)
# Основа: Viktor45/mh-templates stargate.yaml, коммит {commit}
# Сгенерировано scripts/stargate-adapt.py — правьте скрипт, а не этот файл.
#
# ЧТО ИЗМЕНЕНО ОТНОСИТЕЛЬНО ОРИГИНАЛА (ищите метку [VPNX]):
#   1. AUTO: добавлен AWG_FAILOVER перед MANUAL — при отказе всех Xray-серверов
#      трафик уходит в AWG, а не напрямую (DIRECT).
#   2. YouTube: по умолчанию DIRECT, мимо VPN (решение владельца: экономит
#      канал выходных нод; в оригинале был RU_AUTO, а RU-серверов у Tavrida нет).
#   3. Ru-Traffic: по умолчанию DIRECT — российские сайты не пускают с зарубежных IP.
#   4. Torrent-Traffic: по умолчанию DIRECT — на выходных нодах торренты заблокированы.
#   5. QUIC (UDP/443): по умолчанию REJECT — браузеры откатываются на TCP, через
#      прокси это стабильнее (так же в docs/client-templates.md).
#   6. Фильтр «российских» серверов: только флаг 🇷🇺 или отдельное слово RU
#      (в оригинале ловил «ru» в любом месте имени).
#
# УСТАНОВКА НА РОУТЕР (контейнер wiktorbgu/mihomo-mikrotik):
#   - файл кладётся в  <mount>/etc/template/  под именем из env CONFIG
#     (у нас CONFIG=stargate.yaml → template/stargate.yaml);
#   - env SUB1=<ссылка подписки Remnawave> — своя на каждом роутере;
#   - AWG: <mount>/etc/awg/AWG-US.conf (конфиг клиента из wg-easy), см. docs/awg.md;
#   - env UI_SECRET=<пароль> — ОБЯЗАТЕЛЬНО: веб-панель слушает 0.0.0.0:9090,
#     без секрета любой в LAN может переключить или выключить VPN;
#   - после замены: /container stop … ; /container start …
#   - store-selected: true — ранее сохранённый выбор групп переживает смену
#     шаблона; чтобы применились новые умолчания, удалите <mount>/etc/cache.db.
#
# Секретов в файле нет: подписка и ключи подставляются образом при старте.
# ============================================================================
"""

UPSTREAM_HEADER = """# ============================================================================
# ШАБЛОН STARGATE
# Полная конфигурация Mihomo/Meta с расширенными возможностями маршрутизации
# Включает поддержку ZKEEN геоданных, GEOIP/GEOSITE правил и CDN-провайдеров
# Документация: https://github.com/MetaCubeX/mihomo/blob/Meta/docs/config.yaml
# Источник: https://raw.githubusercontent.com/Viktor45/mh-templates/refs/heads/main/stargate.yaml
# ============================================================================
"""


def adapt(t: str, commit: str) -> str:
    def rep(old: str, new: str) -> None:
        nonlocal t
        c = t.count(old)
        if c != 1:
            sys.exit(f"[x] upstream изменился: ожидалось 1 вхождение, найдено {c}:\n    {old[:100]!r}")
        t = t.replace(old, new)

    rep(UPSTREAM_HEADER, HEADER.format(commit=commit))

    # 6. Фильтр RU — только флаг или отдельное слово (RE2 поддерживает \b)
    rep('exclude_ru: &exclude_ru "(?i)🇷🇺|RU"',
        "exclude_ru: &exclude_ru '(?i)🇷🇺|\\bRU\\b'   # [VPNX] только флаг или отдельное слово RU")
    rep('filter_ru: &filter_ru "(?i)🇷🇺|RU"',
        "filter_ru: &filter_ru '(?i)🇷🇺|\\bRU\\b'   # [VPNX] только флаг или отдельное слово RU")

    # 3-4. Список «по умолчанию напрямую» + 2. YouTube через SELECTOR
    rep("""# Специальный список для YouTube (с приоритетом российских прокси)
""", """# [VPNX] Список «по умолчанию напрямую» — для Ru-Traffic и Torrent-Traffic
proxy_list_direct_first: &proxy_list_direct_first
  - DIRECT
  - SELECTOR
  - AUTO
  - LOADBALANCE
  - MANUAL
  - AWG_AUTO
  - AWG_MANUAL
  - RU_AUTO
  - RU_LOADBALANCE
  - RU_MANUAL

# Специальный список для YouTube ([VPNX] DIRECT первым — YouTube мимо VPN)
""")
    rep("""proxy_list_youtube: &proxy_list_youtube
  - RU_AUTO
  - RU_LOADBALANCE
  - RU_MANUAL
  - SELECTOR
""", """proxy_list_youtube: &proxy_list_youtube
  - DIRECT            # [VPNX] по умолчанию YouTube мимо VPN (решение владельца)
  - SELECTOR
  - RU_AUTO
  - RU_LOADBALANCE
  - RU_MANUAL
""")
    # DIRECT переехал в начало списка YouTube — убираем исходный хвостовой дубль
    rep("""  - AUTO
  - LOADBALANCE
  - MANUAL
  - DIRECT
""", """  - AUTO
  - LOADBALANCE
  - MANUAL
""")
    for name, why in (("Ru-Traffic", "RU-сайты не пускают с зарубежных IP"),
                      ("Torrent-Traffic", "на выходных нодах торренты заблокированы")):
        m = re.search(rf"(  - name: {re.escape(name)}\n(?:    (?!proxies:)[^\n]*\n)*?)    proxies: \*proxy_list_all[^\n]*\n", t)
        if not m:
            sys.exit(f"[x] upstream изменился: не найдена группа {name} с proxies: *proxy_list_all")
        t = t[:m.start()] + m.group(1) + f"    proxies: *proxy_list_direct_first   # [VPNX] по умолчанию DIRECT: {why}\n" + t[m.end():]

    # 5. QUIC — REJECT первым
    rep("""    proxies:
      - PASS                        # Пропустить без изменений
      - REJECT                      # Заблокировать""", """    proxies:
      - REJECT                      # [VPNX] по умолчанию: браузер откатится на TCP — через прокси стабильнее
      - PASS                        # Пропустить без изменений""")

    # 1. AUTO → AWG_FAILOVER перед MANUAL
    m = re.search(r"  - name: AUTO\n    type: fallback[^\n]*\n    proxies:\n      - FASTEST[^\n]*\n      - FAILOVER[^\n]*\n(?=      - MANUAL)", t)
    if not m:
        sys.exit("[x] upstream изменился: блок AUTO (FASTEST, FAILOVER, MANUAL) не найден")
    t = t[:m.end()] + "      - AWG_FAILOVER                # [VPNX] при отказе всех Xray — в AWG, а не DIRECT\n" + t[m.end():]
    return t


def main() -> None:
    if len(sys.argv) > 1:
        src = Path(sys.argv[1]).read_text(encoding="utf-8")
        commit = "локальный файл " + Path(sys.argv[1]).name
    else:
        with urllib.request.urlopen(UPSTREAM_URL, timeout=30) as r:
            src = r.read().decode("utf-8")
        commit = upstream_commit()
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "stargate-tavrida.yaml"
    out.write_text(adapt(src, commit), encoding="utf-8")
    print(f"[+] {out} (upstream {commit}), правок [VPNX]: {out.read_text(encoding='utf-8').count('[VPNX]')}")


if __name__ == "__main__":
    main()
