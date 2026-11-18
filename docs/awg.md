# AmneziaWG-контур (уровень E, ADR-0008 / ADR-0020)

Независимый от Xray канал: другой протокол (UDP), другой IP, не управляется
Remnawave. Цель — чтобы при блоке Xray-контура (или IP его нод) у людей
оставался рабочий путь.

## Что развёрнуто (на 2026-11-18)

Три независимых сервера (разные хостеры/AS, свои H1–H4 и `HeaderProtectionKey`):

| | `AWG-US` | `AWG-US2` (ADR-0024) | `AWG-US3` (ADR-0025) |
|---|---|---|---|
| Адрес | 45.86.72.147 (US) | 80.66.75.195 (US, AS400992) | 108.165.184.191 (US, Ace Data Centers / InterLIR) |
| SSH | 22022 | 22022, **только через jump панели** — из KZ порты закрыты на стороне хостера | 22022 |
| UDP-порт | 33482 | 31993 | 32771 |
| Ядро / режим | 7.0.0-43 / userspace | 6.8 / userspace | 6.8 / userspace |
| Клиенты в wg-easy | `tavrida-<роутер>` | `us2-tavrida-<роутер>` (резерв) | `us3-tavrida-<роутер>` (резерв) |
| Файл на роутере (`/etc/mihomo/awg/`) → прокси Mihomo | `AWG-US.conf` → `AWG-US` | `AWG-US2.conf` → `AWG-US2` | `AWG-US3.conf` → `AWG-US3` |
| IPv6 в туннеле | есть | есть | **нет** — у хостера нет IPv6; `AllowedIPs = 0.0.0.0/0` |

Общее для всех:

| | |
|---|---|
| Сервер | отдельный VPS, без Xray — блок IP одной из нод не задевает AWG |
| Софт | wg-easy **15.5.0** (версия закреплена в `70-awg.sh`), AmneziaWG **3.1** |
| Режим | userspace `amneziawg-go` — модуль ядра `amneziawg-dkms` не собирается на свежих ядрах (Ubuntu 26.04, 7.0.0-43: изменился `setup_udp_tunnel_sock`) |
| Обфускация | `HeaderProtectionKey` + S1–S4 ≥ 12 (S2 ≠ S1+56) + `ContentPaddingAddition 0-24`, H1–H4 случайные непересекающиеся (wg-easy не принимает 1–4) |
| MTU / keepalive клиентов | 1280 / 25 с (по умолчанию для новых клиентов) |
| IPv6 | сеть Docker с `enable_ipv6` + ULA, иначе `::/0` клиента уходит в никуда. Если у сервера нет внешнего IPv6 — `defaultAllowedIps`/`allowedIps` клиентов = `0.0.0.0/0` |
| Web UI | только `127.0.0.1:51821`, доступ через SSH-туннель |
| Торренты | блокируются на сервере: цепочка `AWG-P2P` в `DOCKER-USER` (сигнатуры BT-рукопожатия, DHT, трекеров; первые 20 пакетов соединения), юнит `awg-p2p-block.service`. Шифрованный BT (MSE/PE) и чистый uTP не ловятся. Счётчики: `iptables -L AWG-P2P -v -n` |
| Проверено | `amneziawg-go`, Mihomo **1.19.30** и **1.19.33** — IPv4+IPv6; рукопожатие и трафик **из РФ** (DC fvds.ru) |

## Развёртывание с нуля

```bash
# 1. Подготовка: SSH-ключ на сервере, затем
bash 00-hardening.sh --role awg --awg-port <случайный 30000-60999> --ssh-port 22022
# 2. AWG
bash 70-awg.sh --port <тот же порт> --host <нейтральный домен или IP>
# 3. Параметры 3.1 — UI: Admin → Interface (AmneziaWG) или API POST /api/admin/interface:
#    headerProtectionKey (32 байта base64), s1..s4 >= 12, contentPaddingAddition "0-24", mtu 1280
# 4. UI: Admin → User config: defaultMtu 1280, defaultPersistentKeepalive 25
```

`70-awg.sh` сам предупредит, если после старта нет `Jc` (значит поднялся
голый WireGuard) или нет `HeaderProtectionKey` (режим 2.x).

## Доступ к UI

```bash
ssh -p 22022 -L 51821:127.0.0.1:51821 root@<сервер>
# → http://127.0.0.1:51821, admin / пароль в /root/awg-admin-password
```

Первым делом — включить 2FA (Account → 2FA).

## Клиенты

| Клиент | Как подключать |
|---|---|
| AmneziaWG / Amnezia VPN (Android, iOS, Windows, macOS) | `.conf` или QR из UI. Нужна версия с поддержкой 3.x |
| **Mihomo** (в т.ч. на MikroTik), FlClash | `scripts/awg-to-mihomo.py client.conf "🛡 AWG"` → блок в `proxies:` локального конфига. Нужен Mihomo ≥ 1.19.30 и **`version: 3`** в `amnezia-wg-option` — без него ключ 3.x отвергается (`IPC error -22`, mihomo#3118) |
| Happ, INCY, v2rayN и др. Xray-клиенты | ❌ AWG не поддерживают |
| Клиенты AWG 2.x | ❌ с параметрами 3.x не работают |

Ключи у каждого клиента свои, поэтому через общий шаблон подписки Remnawave
AWG не раздаётся. На роутерах Mihomo блок добавляется в **локальный** конфиг и
ставится **последним** в `fallback`-группу после серверов из подписки:

```yaml
proxies:
  - name: "🛡 AWG"
    type: wireguard
    server: <домен>            # домен, а не IP: при блоке IP меняется только A-запись
    port: <порт>
    ip: 10.8.0.N
    ipv6: fdcc:…::N
    private-key: PASTE_CLIENT_PRIVATE_KEY
    public-key: PASTE_SERVER_PUBLIC_KEY
    pre-shared-key: PASTE_PSK
    allowed-ips: ['0.0.0.0/0', '::/0']
    mtu: 1280
    udp: true
    persistent-keepalive: 25
    amnezia-wg-option:
      version: 3               # обязательно для 3.x
      jc: …
      jmin: …
      jmax: …
      s1: … / s2: … / s3: … / s4: …
      h1: … / h2: … / h3: … / h4: …
      header-protection-key: "PASTE_HPK"
      content-padding-addition: "0-24"
```

Если подписка на роутере подключена как **готовый целиком конфиг** (а не через
`proxy-providers`), локальный блок затрётся при обновлении — тогда подписку
надо перевести в `proxy-providers`.

## Роутеры Tavrida: MikroTik + `wiktorbgu/mihomo-mikrotik` + Stargate

Образ сам делает почти всё: при старте парсит `/etc/mihomo/awg/*.conf`
(AWG 3.x распознаётся, `version: 3` ставится автоматически), подключает их
провайдером `AWG` и собирает `stargate.yaml` из `template/<CONFIG>` через
`envsubst`. **Править собранный `stargate.yaml` бесполезно** — он
перезаписывается при каждом старте; правится только шаблон.

Шаблон для раздачи — `stargate-tavrida.yaml` в корне репозитория, генерируется
`scripts/stargate-adapt.py` из актуального upstream (правки помечены `[VPNX]`,
список — в шапке файла). Главное: `AUTO` при отказе всех Xray уходит в
`AWG_FAILOVER`, а не в DIRECT; YouTube — через VPN; RU-сайты и торренты — напрямую.

Установка на роутер:

| Что | Куда / как |
|---|---|
| `stargate-tavrida.yaml` | `<mount>/etc/template/stargate.yaml` (имя = env `CONFIG`) |
| `.conf` клиента из wg-easy | `<mount>/etc/awg/AWG-US.conf` (в имени не должно быть слова RU) |
| env `SUB1` | ссылка подписки Remnawave этого пользователя |
| env `UI_SECRET` | пароль веб-панели — **обязательно**, иначе `0.0.0.0:9090` открыт всей LAN |
| применить | `/container stop …` → `/container start …`; для новых умолчаний групп удалить `<mount>/etc/cache.db` (`store-selected`) |

Проверено в образе (Mihomo 1.19.33): `mihomo -t` ок, при мёртвых Xray трафик
идёт в AWG (IPv4+IPv6), `youtube.com → YouTube[AWG]`, `ya.ru`/`gosuslugi.ru →
Ru-Traffic[DIRECT]`, без `UI_SECRET` API отвечает 401.

## Не сделано / открыто

- `I1` (мимикрия первого пакета) не задан: пример из документации Amnezia
  явно «не сигнатура», собственную стоит подбирать отдельно.
- Модуль ядра — вернуться, когда `amneziawg-dkms` обновится под ядро 7.0.0-43+
  (kernel-режим быстрее userspace; для десятков клиентов не критично).
