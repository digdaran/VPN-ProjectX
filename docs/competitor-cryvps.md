# Разбор подписки CryVPN (2026-11-08) и план внедрения

Пробная подписка стороннего RU-VPN сервиса (cryvps.com), получена владельцем
проекта. Цель — посмотреть, **как** сделаны настройки, и взять то, что
применимо к нашей схеме. Второй такой разбор после vk-proxy
([`client-templates.md`](client-templates.md)). Секреты (UUID, ключи) и IP их
серверов сюда не переносятся — только приёмы.

---

## 1. Как получали

| Шаг | Что вышло |
|---|---|
| Запрос без заголовков устройства | Во **всех** форматах — заглушка `vless://…@0.0.0.0:1` «Переустанови приложение!» |
| С `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model` | Настоящие данные (заняло 1 устройство в лимите пробной подписки) |

Это **Remnawave** с включённым HWID (`x-hwid-active: true`, группа в YAML
называется `→ Remnawave`). Заглушка без HWID — штатное поведение панели:
старые клиенты, не умеющие HWID, получают понятную инструкцию вместо ошибки.

## 2. Что получает каждый клиент

| User-Agent | Тело | Заголовки-настройки приложения |
|---|---|---|
| Happ | Xray JSON, 35 конфигов, ~314 КБ | фрагментация, шум (DNS-пакет), per-app bypass, `ping-type` |
| **INCY** | **тот же JSON байт в байт** | фрагментация, шум (`rand`), per-app bypass, `no-limit-enabled` |
| v2rayN / v2rayNG | base64, 35 ссылок | — |
| Mihomo / FlClash / **FlClashX** | YAML, 35 прокси, 1 группа, 6 правил (одинаковый) | только объявление/название/HWID |
| sing-box (SFA) | JSON, 25 outbound (без XHTTP — sing-box его не умеет) | — |

→ Тело — по формату клиента, **настройки приложения — отдельным набором
заголовков под каждый клиент** (Response Rules с `responseModifications.headers`).

## 3. Серверы и транспорт

| Что | У них | У нас (на 2026-11-08) |
|---|---|---|
| SNI | **свой домен на каждую ноду** (`west.cry-pay.top`, `nord.crynodebest.top`…); DNS → сама нода (или соседний IP пары), **Let's Encrypt** на этом домене — настоящий self-steal | бренды (`www.microsoft.com`, `github.com`, `www.spotify.com`…) на IP VPS — ровно признак, который ТСПУ ловит с 2026-02 |
| Fingerprint | **`qq`** (XHTTP/gRPC/Vision), `firefox` — только LTE-хосты | `firefox` |
| Транспорты на страну | **XHTTP :443 + gRPC :2087/8443**; часть — TCP+Vision | XHTTP Direct :443 + Stream-Up :2087 |
| Фрагментация | `finalmask: {tcp: [{type: fragment, packets: tlshello, length: 10-20, delay: 0}]}` на 27 из 35 хостов | нет |
| XHTTP-тюнинг | **никакого**: только `mode: auto` + путь | xmux `2-3`, `xPaddingBytes 100-1000`, sc*-параметры |
| RU-серверы | TCP + Vision + Reality, SNI `www.yandex.ru` | RU-Gate: XHTTP + self-steal |
| Совместимость с Mihomo | **все XHTTP/gRPC/Vision работают** в Mihomo 1.19.33 (значит, Xray у них < 26.9.8, см. ADR-0021) | работало после отката KZ/MD (ADR-0021) |
| Доступность из РФ (ДЦ) | все обычные ноды — ✅ | FI/FI2/FR/DE — ❌ блок IP |

Особые хосты:

| Группа | Как устроено | Вывод |
|---|---|---|
| «LTE-обход» | хосты на чужих доменах (`*.xrent.cloud`, `*.whitenw.net`), **SNI = голый IP** из белого списка, Vision + `firefox` + fragment. Из ДЦ РФ не отвечают, из США — работают | арендованная инфраструктура под белые списки мобильных операторов; у себя не повторить без такой аренды |
| `max.ru` + `sudoku` | в ссылках/YAML/sing-box: адрес `max.ru`, `security=none`, VLESS Encryption `mlkem768x25519plus` + `finalmask: sudoku` (пароль на «фронт»). Mihomo — `503` | **для не-Happ клиентов это заглушки**: в Happ/INCY JSON те же пункты — реальные балансировщики на обычные Reality-ноды |
| Турция | XHTTP, SNI `<ip>.sslip.io` | self-steal без своего домена: wildcard-DNS sslip.io + LE-сертификат на него |

## 4. Профили Happ/INCY (Xray JSON на хост)

**Балансировщики.** Один пункт списка = много outbound:

| Пункт | Внутри | Стратегия |
|---|---|---|
| «Авто выбор VPN» | 35 outbound (все страны, дубли = вес) | `leastLoad` |
| «Москва» | 2 RU-сервера | `roundRobin`, `burstObservatory` каждые 10 мин |
| «Gemini» | 2 ноды | `leastPing` |
| «Авто обход LTE» | 8 LTE-outbound | `leastLoad` |

**Маршрутизация** (5–9 правил, `IPIfNonMatch` / `IPOnDemand`):

| Правило | Куда |
|---|---|
| `protocol: bittorrent` | **direct** — торренты мимо VPN прямо на устройстве |
| `port: 3389` (RDP) | direct |
| 278 сервисов определения IP (2ip, ipinfo, …) | **через VPN** |
| `.ru/.su/.рф`, `geosite:category-ru`, `geoip:ru`, Авито, ivi, Сбер | direct |
| «Банки LTE»: Сбер, Т-Банк и др. (~38 доменов) | **через VPN**; Госуслуги, налоговая, mos.ru, RuStore (~80) — direct |
| остальное | балансировщик / proxy |

DNS: для RU-доменов — Яндекс `77.88.8.8` (`skipFallback`), остальное — 8.8.8.8 / 1.1.1.1.
Запасной outbound `frag` — freedom с `fragment` (50–100, tlshello).

## 5. Заголовки-настройки приложения

| Заголовок | Happ | INCY |
|---|---|---|
| `fragmentation-*` | tlshello, 50–100, интервал 5, maxsplit 100–200 | tlshello, 50–100, интервал 5 |
| `noises-*` | **готовый DNS-запрос** к `t-ring.msedge.net` (base64), 1–1024, 50 мс | `rand` 10–20 байт, 10–50 мс |
| `per-app-proxy-mode/list` | `bypass: ru.oneme.app` — **мессенджер MAX мимо VPN** | то же |
| прочее | `ping-type: tcp` | `no-limit-enabled: 1` |
| общие | `profile-update-interval: 1` (час), **`fallback-url`** (резервный домен подписки), `announce` (текст в клиенте: «за торренты бан 24 ч»), `support-url`, HWID | |

---

## 6. План внедрения

Порядок — по соотношению польза/трудозатраты. «Кому» — какие клиенты получат эффект.

| # | Что | Где у нас | Кому | Трудоёмкость / риск |
|---|---|---|---|---|
| 1 | **Self-steal на своём домене для каждой ноды** вместо брендовых SNI | Нода: `scripts/30-selfsteal.sh` + `configs/nginx-selfsteal.conf`; DNS `v<страна>.08u.ru` уже есть для FI/FI2/KZ; хост в панели: `sni`/`host`; инбаунд: `serverNames`/`dest` | всем | средняя: на каждую ноду nginx + LE; начать с одной (KZ) и сравнить. Обязательно: 50-preflight (инвариант 2 CLAUDE.md) |
| 2 | **`finalmask: fragment`** (tlshello, 10–20) на хостах | Хост → поле `final_mask` (уже есть в БД, у всех пусто) | Happ, INCY, v2rayN (Xray-клиенты) | низкая; Mihomo поле игнорирует — вреда нет. Проверить на 1–2 хостах |
| 3 | **Response Rules с заголовками для Happ и INCY**: fragmentation, noises, `per-app bypass ru.oneme.app`, `fallback-url`, `announce` | `subscription-settings.responseRules` → `responseModifications.headers` (как у правил Mihomo/Stash) | Happ (10 чел.), INCY (16 чел.) | низкая; сейчас для них работает правило-фолбэк без заголовков. Шум — для Happ взять тот же приём «настоящий DNS-пакет» (свой, не их) |
| 4 | **gRPC как второй транспорт** на страну (вместо/вместе со Stream-Up) | Профиль ноды: новый инбаунд `grpc-in-*`, хост `· gRPC` | все, включая Mihomo | средняя: инбаунд + порт + ufw + preflight |
| 5 | **Xray-JSON-шаблон для Happ/INCY**: `bittorrent → direct`, RU → direct, балансировщик «Авто» (`leastPing`) | Хост → `xray_json_template_uuid` (Templates типа XRAY_JSON) | Happ, INCY | средняя; сравнить с текущим `client-hardened-routing.json` |
| 6 | **Попробовать `fp=qq`** на одном хосте | Хост → `fingerprint` | все (Mihomo тоже знает `qq`) | низкая; A/B на одном хосте, т.к. наш опыт на `firefox` положительный |
| 7 | Резервный домен подписки (`fallback-url`) | второй поддомен → та же subscription-page | Happ/INCY | низкая |

**Не берём:**

- `max.ru` + `sudoku` для не-Happ клиентов — это заглушки, а не рабочий транспорт.
- «LTE-обход» через арендованные хосты на чужих доменах — зависимость от третьих лиц; наш аналог — RU-Gate с IP из белого списка (ADR-0009, уровень C+).
- Отказ от xmux/padding в XHTTP — у них это упрощение, а не находка; наши
  параметры обоснованы (tspu-checklist, звено 3).
- 278 сервисов определения IP **через** VPN — спорно: российские приложения,
  которые сообщают внешний IP (методичка Минцифры), увидят IP выхода. Вопрос
  открыт, решать отдельно.

**Ограничения, о которых помнить:**

- Пункты 2, 3, 5 — только Xray-клиенты (Happ, INCY, v2rayN). Mihomo-клиентам
  (Tavrida, FlClash) помогают только 1, 4, 6.
- Любой апгрейд Xray на нодах выше 26.7.x ломает Mihomo — ADR-0021.
