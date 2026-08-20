# Формат подписки под разных клиентов: Templates / Response Rules в Remnawave

Один и тот же URL подписки может отдавать **разное содержимое разным
клиентским приложениям** — не потому что где-то стоит самописная логика, а
потому что это штатная функция **Remnawave** (панель по умолчанию в этом
проекте, см. README §2, [`../DECISIONS.md`](../DECISIONS.md) ADR-0001).
Актуально на август 2026.

---

## Откуда это взялось

При разборе пробной подписки стороннего RU-VPN сервиса (vk-proxy.com,
2026-08-15) обнаружилось: один и тот же URL под разным `User-Agent` отдавал
три разных тела ответа — голый список `vless://`-ссылок, JSON для sing-box и
YAML для Clash/Mihomo. Дальнейшая проверка показала, что их Mihomo-профиль
почти дословно совпадает с публичным community-шаблоном **"RoscomVPN Mihomo
RU"** из официального каталога [`remnawave/templates`](https://github.com/remnawave/templates).
Вывод: это не собственная разработка конкурента, а штатная возможность той же
панели, что уже используется в этом проекте — мы её просто не задействовали.

---

## Как это работает в Remnawave

- Раздел **Templates** в панели хранит шаблоны подписки по типу core:
  Xray JSON, Mihomo/Clash YAML, Singbox JSON и т.д.
- **Response Rules** (он же Routing Rules; несколько шаблонов на один core —
  с версии Remnawave **2.2.0**) сопоставляют запрос конкретному шаблону по
  `User-Agent` запроса, либо по Squad/группе пользователя.
- Если ни одно правило не совпало — отдаётся шаблон по умолчанию.

Подробности механики (UI, точный синтаксис правил) — в официальной
документации: [docs.rw/learn-en/templates](https://docs.rw/learn-en/templates/).
Этот проект не форкает и не дублирует эту документацию — только то, что
специфично для нашей схемы (ниже).

**Важно: сам по себе файл шаблона в этом репозитории ничего не меняет.**
Чтобы он реально начал отдаваться, его нужно вручную загрузить в
Templates и настроить Response Rules в панели — это шаг в UI, не покрытый
`scripts/`.

---

## Какой файл этого репозитория для какого клиента

| Клиент | Формат | Файл в этом репозитории | Тип шаблона в Remnawave | Статус на проде (`hulgn.08u.ru`) |
|---|---|---|---|---|
| INCY, голый Xray-core, большинство остальных (Happ, v2rayNG, Streisand, NekoBox, v2rayN, Hiddify без TUN…) | Xray JSON / `vless://` URI | [`../configs/client-example.json`](../configs/client-example.json), [`../configs/client-multi-profile.json`](../configs/client-multi-profile.json) | XRAY_JSON / `XRAY_BASE64` (fallback-правило) | Работает из коробки, без Template — обычная подписка Remnawave |
| Clash Meta / Karing (regex `^(?:flclash\|flowvy\|murge\|mihomo\|prizrak-box\|koala-clash\|clash...)`) | Mihomo YAML | [`../configs/client-mihomo-dropweb.yaml`](../configs/client-mihomo-dropweb.yaml) | MIHOMO | ✅ **Активен с 2026-08-20** — см. раздел ниже |
| — резерв для MIHOMO, не активен (был активен до 2026-08-20) | Mihomo YAML | [`../configs/client-mihomo-ru.yaml`](../configs/client-mihomo-ru.yaml) | MIHOMO (шаблон «Default») | 🟡 Применено 2026-08-15, заменено на dropweb-mihomo — переключение назад см. ниже |
| Clash (обычный, `^clash`, без meta-суффикса) | тот же YAML, что и MIHOMO | [`../configs/client-mihomo-ru.yaml`](../configs/client-mihomo-ru.yaml) | CLASH | ✅ Применено 2026-08-15 (см. обоснование ниже) |
| Stash (iOS/macOS, `^stash`) | тот же YAML, что и MIHOMO | [`../configs/client-mihomo-ru.yaml`](../configs/client-mihomo-ru.yaml) | STASH | ✅ Применено 2026-08-15 (см. обоснование ниже — НЕ community-шаблон Stash) |
| sing-box нативный (`sfa\|sfi\|sfm\|sft\|karing\|singbox`) | Singbox JSON | [`../configs/client-singbox-ru.json`](../configs/client-singbox-ru.json) | SINGBOX | ✅ Применено 2026-08-15 (форк с исправлениями, см. ниже) |
| — (нет активного Response Rule) | Xray JSON | — | XRAY_JSON | Пусто, не трогали — ни одно из 6 текущих Response Rules на это не указывает |

INCY официально числится в списке клиентов Remnawave — Xray-core,
VLESS/VMess/Trojan/Shadowsocks, поддержка HWID-лимита устройств
([docs.rw/clients](https://docs.rw/clients/)). Родной формат для него —
обычный Xray JSON, то есть уже то, что есть в `configs/`. Никакого
специального шаблона под INCY заводить не пришлось.

---

## `configs/client-mihomo-ru.yaml`: форк «RoscomVPN Mihomo RU»

Источник: [`by-roscomvpn/subscription-templates/roscomvpn-mihomo-ru.yaml`](https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-roscomvpn/subscription-templates/roscomvpn-mihomo-ru.yaml)
(автор ristavor, при участии hydraponique и fatyzzz — атрибуция сохранена в
шапке файла).

Взят практически 1:1 — rule-sets поддерживаются сообществом (репозитории
`hydraponique/roscomvpn-geosite`, `roscomvpn/custom-category`,
`legiz-ru/mihomo-rule-sets`), свой форк только протухнет без сопровождения.
Изменения — только уточняющие комментарии, без изменения логики:

| Что | Апстрим | В нашем форке |
|---|---|---|
| Telegram | `PROXY` | Оставлено `PROXY` — с комментарием не переключать в `DIRECT` бездумно (в живом ответе vk-proxy.com было переключено — это их локальная правка поверх этого же шаблона, не свойство апстрима) |
| QUIC (UDP:443) | `REJECT-DROP` | Без изменений. Тот же приём, что независимо добавлен в `configs/client-example.json` как Xray routing-правило (см. его комментарий про происхождение) — здесь эффективнее, т.к. Mihomo обычно работает в TUN-режиме и видит весь системный UDP, а не только то, что явно отправлено в SOCKS |
| Торренты | `DIRECT` (мимо тоннеля) | Без изменений — но отмечено, что для нас это ещё и защита белого IP выходных нод от абузов, то есть та же цель, что у проверки `protocol: bittorrent → block` в `scripts/50-preflight.sh`, только на стороне клиента, а не сервера |
| Игровые категории (Steam/Epic/Origin/Riot/EfT/FaceIT) и Discord.exe по имени процесса | Активны, группа `🎮 Игры` DIRECT по умолчанию | **Закомментированы (2026-08-15)** — не удалены, весь `proxy-group`/`rule-providers`/`rules` остался в файле как неактивный YAML, помечен тегами `ВКЛЮЧИТЬ ИГРЫ:`/`ВКЛЮЧИТЬ DISCORD:`. Причина: аудитория проекта — 10–100 личных пользователей (README «Область применения»), не игровой сервис. Без явного правила этот трафик просто идёт через общий `MATCH,PROXY`, не теряется |

Два маркера `# LEAVE THIS LINE!` в файле — точки инъекции Remnawave (панель
подставляет туда реальные vless-записи ваших нод при генерации подписки).
Они побайтово совпадают с апстримом и **не должны редактироваться**.

### Ограничения

- **Не проверяется `scripts/50-preflight.sh`** — скрипт глобит только
  `configs/*.json` и `configs/ready/*.json`. `.yaml`-шаблон вне этого
  контура; проверять руками.
- **Не парный к `configs/ready/`** — инвариант CLAUDE.md про
  `configs/*.json` ⟷ `configs/ready/*.json` (побайтовая сверка через
  `strip_comments`) на YAML не распространяется: комментарии здесь нативные
  (`#`), отдельного «очищенного» файла не требуется.
- Игровые категории и Discord.exe закомментированы (см. таблицу выше) —
  если аудитория поменяется, раскомментируйте блоки, помеченные
  `ВКЛЮЧИТЬ ИГРЫ:`/`ВКЛЮЧИТЬ DISCORD:` в файле (`proxy-groups`,
  `rule-providers`, `rules` — все три места помечены одинаково).

### Как включить

**Шаг 1 — загрузить шаблон.** В панели: **Templates → Add Template**, тип
`MIHOMO`, вставить содержимое `configs/client-mihomo-ru.yaml` целиком (вместе
с закомментированными игровыми блоками — они неактивны, но пусть останутся
на месте для единообразия с этим репозиторием). Дать шаблону понятное имя,
например `RoscomVPN Mihomo RU (VPN-ProjectX)`.

**Шаг 2 — добавить Response Rule.** Правила живут в **Subscription →
Response Rules** (в документации иногда называются Routing Rules / SRR —
Subscription Response Rules); полная спецификация —
[docs.rw/docs/learn-en/routing-rules](https://docs.rw/docs/learn-en/routing-rules/).
Правила проверяются **сверху вниз, первое совпавшее останавливает разбор** —
самое специфичное правило должно стоять выше общего.

Структура правила (проверено по офиц. документации на 2026-08-15):

```json
{
  "name": "Clash / Mihomo family",
  "description": "Отдаёт RoscomVPN Mihomo RU тем, кто представился Clash-совместимым клиентом",
  "enabled": true,
  "operator": "OR",
  "conditions": [
    { "headerName": "user-agent", "operator": "CONTAINS", "value": "clash", "caseSensitive": false },
    { "headerName": "user-agent", "operator": "CONTAINS", "value": "mihomo", "caseSensitive": false },
    { "headerName": "user-agent", "operator": "CONTAINS", "value": "stash", "caseSensitive": false },
    { "headerName": "user-agent", "operator": "CONTAINS", "value": "karing", "caseSensitive": false }
  ],
  "responseType": "MIHOMO",
  "responseModifications": {
    "subscriptionTemplate": "RoscomVPN Mihomo RU (VPN-ProjectX)"
  }
}
```

Важные детали из спецификации:

- `operator` на верхнем уровне: `OR` — сработает, если совпало хоть одно из
  условий (нужно, т.к. у Clash/Mihomo/Stash/Karing разные UA-строки);
  `AND` — нужны все условия сразу (пример из документации: отдельный JSON
  для Happ именно на Android — UA содержит `happ` **и** заголовок
  `x-device-os` равен `android`).
- `operator` внутри условия: `CONTAINS`, `EQUALS`, `STARTS_WITH`, `REGEX` и
  другие — `CONTAINS` обычно достаточно для UA-строк клиентов.
- Пустой массив `conditions` совпадает со всем — удобно для fallback-правила
  в самом низу списка (Xray JSON/`vless://` по умолчанию для всех
  неопознанных UA, это же поведение и без единого правила).
- `responseType` для этого шаблона — `MIHOMO` (совпадает с `type` в
  `subscription-templates-list.json`, см. раздел выше).
- Response Rules **имеют приоритет над External Squads** — если уже
  настроена маршрутизация по сквадам, проверьте, не конфликтует ли она с
  новым правилом.

**Шаг 3 — проверить.** Тем же приёмом, каким разбиралась чужая подписка:

```bash
curl -A "clash-verge/v1.6.6" <ваша ссылка на подписку>
```

Убедиться, что в ответе `proxies:` содержит реальные записи ваших нод
(`ru-entry`, `exit-fr/de/nl/kz`), а не пустой список — иначе Response Rule
не сработала или шаблон загружен с ошибкой.

Точный набор пунктов меню в UI здесь намеренно не расписан детальнее — он
меняется от версии к версии панели быстрее, чем этот репозиторий; структура
самого правила (JSON выше) — часть API/схемы и меняется реже, потому
задокументирована подробно.

---

## Категорийные DIRECT-правила в Xray-JSON профилях (2026-08-15)

`configs/client-multi-profile.json` и черновик `configs/client-hardened-routing.json`
получили те же DIRECT-категории, что в `client-mihomo-ru.yaml`: Microsoft,
Apple, Twitch, Pinterest и игровые платформы (Steam, Epic Games, Origin/EA,
Riot) — не заблокированы в РФ, гонять их через тоннель/балансировщик
незачем. `configs/client-example.json` (одиночный профиль) этот раунд правок
сознательно не затронул — при необходимости переносится тем же способом.

**Важное расхождение с Mihomo-шаблоном:** `escapefromtarkov` и `faceit` у
RoscomVPN — это их собственные кураторские rule-sets (репозиторий
`hydraponique/roscomvpn-geosite`), а не часть стандартной базы geosite,
вшитой в Xray-core (`v2fly/domain-list-community`). Добавление в Xray JSON
несуществующего тега `geosite:...` не игнорируется тихо — роняет загрузку
конфига целиком. Проверено 2026-08-15 прямым запросом к
`raw.githubusercontent.com/v2fly/domain-list-community` — `escapefromtarkov`
и `faceit` там не существуют, `steam`/`epicgames`/`origin`/`ea`/`riot`/
`microsoft`/`apple`/`twitch`/`pinterest` существуют и уже использовались в
проекте (`category-ads-all`, `category-ru`, `category-gov-ru`). Итог: для
Xray JSON набор категорий у́же, чем в Mihomo-шаблоне — это ограничение базы
geosite.dat, не наш недосмотр.

Как и игровой блок в Mihomo-шаблоне, DIRECT для игровых платформ —
допущение, унаследованное из апстрима, а не проверенный на практике факт
именно для этого проекта. Если конкретный сервис на деле недоступен без
тоннеля — уберите его домен из соответствующего правила `routing.rules` в
файле.

---

## Реально применено на проде (`hulgn.08u.ru`, 2026-08-15)

Templates и Response Rules сконфигурированы через REST API панели
(`api/remnawave_client.py` использует тот же принцип — Bearer-токен, без
входа в веб-интерфейс). Ниже — что именно сделано, что найдено по пути и
почему часть готовых community-шаблонов НЕ взята как есть.

### Response Rules не пришлось трогать

На этой инсталляции уже было 6 включённых правил (Browser → BROWSER,
Mihomo Clients → MIHOMO, Stash → STASH, Sing-box clients → SINGBOX, Clash
Core Clients → CLASH, Fallback → XRAY_BASE64) — корректные regex, все
`enabled: true`. Не хватало только содержимого самих Templates: все 5 слотов
(XRAY_JSON/MIHOMO/STASH/CLASH/SINGBOX) были `null`. То есть Mihomo/Stash/
Clash/Sing-box клиенты формально получали ответ 200, но без единой реальной
ноды — конфиг "с виду настроен, а по факту нет".

### Механика API (реальная, отличается от опубликованной OpenAPI-схемы)

Сторонний дамп схемы ([DigneZzZ/remna-admin-bot](https://github.com/DigneZzZ/remna-admin-bot/blob/main/remnawave-api-v2113.json))
утверждает `PUT /api/subscription-templates` без `uuid` в теле. На практике
(проверено запросом): это `PATCH`, и `uuid` обязателен:

```
PATCH /api/subscription-templates
{
  "uuid": "<uuid шаблона из GET /api/subscription-templates>",
  "templateType": "MIHOMO" | "CLASH" | "STASH" | "SINGBOX" | "SINGBOX_LEGACY" | "XRAY_JSON",
  "encodedTemplateYaml": "<base64 YAML>"   // для YAML-типов (MIHOMO/CLASH/STASH)
  "templateJson": { ... }                   // для JSON-типов (SINGBOX/SINGBOX_LEGACY/XRAY_JSON) — сырой объект, НЕ base64
}
```

`uuid` конкретных слотов на этой инсталляции — в ответе `GET /api/subscription-templates`
(там же видно, что `encodedTemplateYaml`/`templateJson` в списке всегда `null`
даже когда шаблон заполнен — реальное содержимое отдаёт только `GET /api/subscription-templates/{uuid}`
или `/{templateType}`).

### MIHOMO / CLASH / STASH: один и тот же файл на все три слота

`configs/client-mihomo-ru.yaml` залит **дословно** (проверено побайтово
через round-trip GET) во все три слота — MIHOMO, CLASH и STASH. Не отдельные
файлы, потому что:

- **CLASH**: на этой же панели штатный `Default Clash` и `Default Mihomo`
  (до правки) оказались побайтово идентичны друг другу — то есть сама
  Remnawave трактует CLASH и MIHOMO одним и тем же рендерящим ядром
  (Clash-Meta-совместимым). Разделять контент не было смысла.
- **STASH**: у community-шаблона `Stash (RU bundle)` от legiz-ru
  ([исходник](https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/stash-ru-bundle.yaml))
  правила заканчиваются на `MATCH,DIRECT` — то есть весь трафик, не
  попавший явно в ru-bundle/cloudflare/youtube/messengers/torrent/apple-push,
  идёт **мимо тоннеля**. Для проекта, чья цель — «доступ к открытому
  интернету» (README «Область применения»), это неподходящая философия по
  умолчанию: любой сайт вне их курируемого списка молча не работает через
  VPN. Сознательно не взяли этот шаблон; Stash технически совместим с
  Mihomo/Clash-Meta YAML (тот же движок), так что переиспользование
  `client-mihomo-ru.yaml` (где дефолт — `MATCH,PROXY`) корректно и
  безопаснее.

### SINGBOX: `configs/client-singbox-ru.json` — форк с тремя реальными фиксами

Источник: [`Singbox (RU bundle, oisd-big)` от legiz-ru](https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/singbox-ru-bundle-oisd-big.json)
— тот же самый файл, что оказался живым sing-box-ответом vk-proxy.com в
самом начале этого расследования (совпадает с их выдачей 1:1, включая
источники rule-set: `legiz-ru/sb-rule-sets`, `hydraponique/RuRulesets`,
`MetaCubeX/meta-rules-dat`).

Проверено реальным `sing-box check` (SagerNet/sing-box v1.13.18, официальный
релиз) — не на глаз. Найдено и исправлено **до** заливки на прод:

| Проблема | Что происходило | Фикс |
|---|---|---|
| `inbound.sniff` / `sniff_override_destination` | Поля, **удалённые в sing-box 1.13.0** (миграция на rule actions). `sing-box check` падал: `FATAL... legacy inbound fields ... removed in sing-box 1.13.0`. Официальный `Default Singbox` от самой Remnawave страдает тем же — проверено отдельно, тоже падает | Убраны с уровня inbound; сниффинг и так уже объявлен через `route.rules: [{"action":"sniff"}]`, дублирование не требовалось |
| `route.override_android_vpn` | `sing-box check` на не-Android: `FATAL... override_android_vpn is only supported on Android`. Поле безусловно стоит в шаблоне, который Remnawave отдаёт **всем** sing-box клиентам сразу (Android/iOS/macOS/Windows/tvOS — один Response Rule на все) | Убрано целиком. Cо стороны Android теряется небольшая оптимизация обхода системного VPN-конфликта; взамен sing-box реально запускается на iOS/macOS/Windows |
| Нет `route.final` | Без явного `final` неотвеченные правила уходят на первый `outbounds[0]` — а это `"direct"`. Тот же класс проблемы, что нашли в отклонённом Stash-шаблоне (см. выше) — «по умолчанию мимо тоннеля» | Добавлено `"route.final": "default"` (то есть на `⚡️ Auto`/реальные ноды) |
| Нет правила для приватных IP | В отличие от официального `Default Singbox` (там есть `{"outbound":"direct","ip_is_private":true}`) и вообще всех остальных наших шаблонов/конфигов — здесь его не было. Локальная сеть тоже пошла бы в `default` после фикса `route.final` выше | Добавлено `{"ip_is_private": true, "outbound": "direct"}` сразу после sniff/hijack-dns |

**Не тронуто сознательно:** устаревший формат `dns.servers` (deprecated в
sing-box 1.12, будет удалён в 1.14) — предупреждение, не фатальная ошибка,
и им страдает **и официальный шаблон Remnawave тоже** (проверено). Полная
миграция на новый DNS-формат — отдельная задача, рискованная без
полноценного повторного тестирования; отложено. Нужно будет решить до
релиза sing-box 1.14.

**Важное отличие от YAML-шаблонов: `_comment`-ключи здесь недопустимы.**
sing-box использует строгий JSON-декодер — лишнее поле верхнего уровня
(`_comment`) валит конфиг: `FATAL... unknown field "_comment"` (проверено).
Поэтому `configs/client-singbox-ru.json` — полностью «чистый» JSON без
пояснений внутри; вся документация по нему — здесь, в этом файле.

### Проверка и уборка за собой

Использовались тестовые сервисные аккаунты `svc-transit-*` (не реальные
подписчики, по указанию владельца проекта) — `curl -A "<UA>" <ссылка>`, как и
при разборе чужой подписки в начале. Все четыре формата (Mihomo/Clash/Stash/
Sing-box) отдают контент правильного размера под правильный UA.

Отдельно обнаружено (не баг шаблонов, а два независимых механизма Remnawave):

1. **Без заголовка `X-HWID`** панель отдаёт заглушку `App not supported`
   (`subscription-settings.customRemarks.HWIDNotSupported`) вместо реальных
   нод — это официальный HWID-device-limit механизм, требует заголовка
   `X-HWID` от клиента при первом добавлении подписки.
2. **С `X-HWID`, но без host'а у сквада** — заглушка меняется на
   `→ Remnawave` (`customRemarks.emptyHosts`). У сервисных `svc-transit-*`
   аккаунтов это ожидаемо: их сквады (`Transit-DE`/`Transit-MD`/…) —
   внутренние транзитные плечи RU→выход, без публичного клиентского host'а
   по архитектуре (README §5.3: «транзитный inbound... не должен быть
   доступен из интернета вообще»).

Тестовый `X-HWID`, зарегистрированный при проверке (2), удалён через
`POST /api/hwid/devices/delete` сразу после — `GET /api/hwid/devices/{id}`
подтверждает `total: 0`.

---

## Найден и исправлен: битый Happ/INCY routing-профиль (2026-08-16)

Реальный пользователь (клиент **INCY**) прислал скриншот ошибки при попытке
подключиться: `infra/conf: invalid field rule > common/geodata: illegal
domain rule: geosite:torrent > ... EOF`. Это тот же класс бага, что чинили
выше в Xray-JSON профилях (несуществующий geosite-тег роняет загрузку
конфига целиком) — но на этот раз не в файлах этого репозитория, а прямо в
живой настройке панели.

### Где нашлось

`subscription-settings.customResponseHeaders.routing` — отдельное поле,
никак не связанное с Templates/Response Rules выше. Это URI вида
`happ://routing/add/<base64 JSON>`, который Remnawave отдаёт клиентам как
кастомный HTTP-заголовок; **INCY, как и Happ, умеет его читать и строить из
него локальный routing-профиль** (это конвенция, не документированная в
самой панели — обнаружена по факту, что INCY на неё падает). Внутри —
свой формат (`DirectSites`/`ProxySites`/`BlockSites`/`DirectIp`/`ProxyIp`/
`BlockIp`, поля `Geoipurl`/`Geositeurl` явно указывают на тот же
`Loyalsoldier/v2ray-rules-dat`, что качает `scripts/20-node-install.sh`) —
но категории в нём набраны из того же RoscomVPN-набора, что и в
`client-mihomo-ru.yaml`, без проверки, что каждый тег реально существует в
этой geosite.dat.

### Что было сломано (проверено поштучно, не на глаз)

Прямые запросы к `raw.githubusercontent.com/v2fly/domain-list-community/master/data/<tag>`
для каждого использованного тега:

| Массив | Битые теги | Существуют |
|---|---|---|
| `DirectSites` | `whitelist`, `escapefromtarkov`, `faceit`, **`ru`** (без `category-`) | `private`, `category-ru`, `microsoft`, `apple`, `epicgames`, `riot`, `steam`, `origin`, `twitch`, `pinterest` |
| `ProxySites` | `twitch-ads` | `google-play`, `github`, `youtube`, `telegram` |
| `BlockSites` | `win-spy`, `torrent` | `category-ads` |
| `DirectIp` | `direct` (в geoip.dat есть `RU`/`CN`/`PRIVATE`, но не `DIRECT`) | `private`, `ru` |

Итого **8 битых тегов** из 24 использованных — треть профиля была
нерабочей. Любой строгий Xray-based клиент (INCY попался первым, но это
общее свойство ядра, не особенность конкретного приложения) падает на
первом же нерабочем теге при попытке применить этот routing-профиль —
`geosite:ru` не первый в списке, поэтому реальная ошибка у пользователя
была именно про `torrent`, но `ru` тоже была бы проблемой, дойди до неё
разбор.

### Фикс

Все 8 тегов убраны из `happ://routing/add/...`, остальные (валидные)
оставлены как есть. `customResponseHeaders` обновлён через
`PATCH /api/subscription-settings` (тело — весь объект `customResponseHeaders`,
не только `routing`, чтобы не затереть `support-url`/`profile-title`/
`profile-web-page-url`/`profile-update-interval` — судя по всему, PATCH
здесь заменяет объект целиком, а не мёржит по ключам). Результат проверен
трижды:

1. Round-trip `GET` — остальные 4 ключа `customResponseHeaders` не задеты.
2. Декодированный `routing` вручную сверен — ни одного из 8 битых тегов не
   осталось, валидные на месте.
3. **Решающая проверка**: итоговые `DirectSites`/`ProxySites`/`BlockSites`/
   `DirectIp`/`ProxyIp`/`BlockIp` собраны в настоящий Xray routing-конфиг и
   прогнаны через `xray run -test` (XTLS/Xray-core v26.3.27, та же сборка,
   что и весь остальной сегодняшний прогон) — `Configuration OK.`

### Урок на будущее

Это уже третий раз за сегодня (после `geolocation-!ru` в клиентских
Xray-JSON профилях и `escapefromtarkov`/`faceit` в переносе категорий из
Mihomo-шаблона), когда geosite-тег из курируемого RoscomVPN-набора
оказывается несуществующим в стандартной geosite.dat. Список надёжно
существующих категорий, использованных в этом проекте и проверенных
поштучно на 2026-08-15/16: `private`, `category-ru`, `category-gov-ru`,
`category-ads`/`category-ads-all`, `microsoft`, `apple`, `epicgames`,
`riot`, `steam`, `origin`, `ea`, `twitch`, `pinterest`, `google-play`,
`github`, `youtube`, `telegram`, `whatsapp`. Ненадёжны (не существуют в
`v2fly/domain-list-community`, и, соответственно, в собранной из неё
`Loyalsoldier/v2ray-rules-dat`): `geolocation-!ru`, `escapefromtarkov`,
`faceit`, `whitelist`, `twitch-ads`, `win-spy`, `torrent`, голый `ru` (без
`category-`), `geoip:direct`. Перед тем как добавлять **любой** новый
geosite/geoip тег куда бы то ни было в этом проекте — проверять его
существование тем же способом (прямой HTTP-запрос к `data/<tag>` в
`v2fly/domain-list-community`), а не полагаться на то, что он есть в
чьём-то чужом Mihomo/Clash-шаблоне.

---

## Второй MIHOMO-шаблон: `configs/client-mihomo-dropweb.yaml` (2026-08-20)

Второй, **не активный** вариант для слота MIHOMO — RoscomVPN-форк выше
остаётся тем, что реально получают пользователи. Заведён как отдельный
именованный шаблон в панели (не замена «Default»), чтобы можно было
переключаться правкой одного поля, не теряя проверенный рабочий вариант.

### Источник и что изменено

Форк [`enkinvsh/dropweb-mihomo`](https://github.com/enkinvsh/dropweb-mihomo)
(`mihomo.ultimate.yml`), автор — читай README апстрима. Отличается от
RoscomVPN-форка выше устройством: свои rule-provider'ы
(`MetaCubeX/meta-rules-dat` + `legiz-ru/mihomo-rule-sets` вместо
`hydraponique/roscomvpn-*`), TLS-фрагментация (`tls-fragment`), большой
Android `tun.exclude-package`.

Убрано относительно апстрима (по прямому запросу владельца проекта —
«много пунктов не нужно», аудитория та же 10–100 личных пользователей):

| Убрано | Что именно |
|---|---|
| Discord | Группа `💬 Discord`, providers `discord_domains`/`discord_voiceips`, все правила на них (включая voice-UDP до QUIC-реджекта), ссылка в DNS `nameserver-policy` |
| Игры | Provider `games-direct`, правило `RULE-SET,games-direct,♻️ DIRECT` |
| Криптобиржи | Provider `crypto-exchanges` + inline `additional-crypto-exchanges`, правило DIRECT — актуально только при реальной торговле с этих IP |
| Телефония Mango Office | `mango-domains`/`mango-ips` providers, все три связанных правила (домены/голые IP/desktop-процесс) — нишевый корпоративный SIP-провайдер |
| Whitelist рекламных кабинетов | DNS `nameserver-policy` (VK Ads/Яндекс Директ+Метрика/GA4/GTM/Adjust/AppsFlyer/Ozon-WB Seller), `fake-ip-filter` для `ads.vk.com`, DOMAIN-SUFFIX правила — нужно только тем, кто ведёт рекламные кампании/продажи |
| «Честный Знак» | `crpt.ru`/`crpt.tech` DIRECT — маркировка товаров, розница |
| Группа `▶️ YouTube` | Свёрнута: правило `RULE-SET,youtube,...` теперь ведёт прямо в `🌍 VPN` вместо отдельного селектора — на один пункт меню меньше |

**Сознательно НЕ тронуто:** `tun.exclude-package` (~400 российских Android
package-имён, ~530 строк). Не пункт меню — Android-специфичный механизм
(`VpnService.addDisallowedApplication()`), исключает конкретные приложения
из TUN-интерфейса на уровне ОС. Нужен потому, что anti-fraud SDK многих
российских банковских/госуслуг-приложений проверяет **сам факт активного
VPN на устройстве** через `ConnectivityManager`, а не то, куда реально
маршрутизируется трафик конкретного приложения — доменные DIRECT-правила
эту проблему в принципе не решают (тот же класс проблемы, что был у
телефонии Mango, только там причина «голый IP без домена», здесь —
«приложению плевать на маршрутизацию, оно смотрит на статус VPN в ОС»).
Поддерживается апстримом (`legiz`, автосборка) — не наша забота по
актуализации, и безвреден на не-Android клиентах (поле просто игнорируется,
подтверждено `mihomo -t`).

### Проверка (не на глаз)

- `mihomo -t` (MetaCubeX/mihomo **v1.19.30**, официальный релиз) — со
  симулированной инъекцией узла на все 5 маркеров `# LEAVE THIS LINE!`
  (было 8 в апстриме — 3 маркера ушли вместе с группами YouTube/Discord/
  Cascade): `test is successful`.
- Все **30** уникальных rule-provider URL прогнаны напрямую (`curl -o
  /dev/null -w '%{http_code}'`) — все `200`. В апстриме была задокументирована
  опечатка `category-crypto-exchanges` (404, правильно
  `category-cryptocurrency`) — на момент проверки уже исправлена в самом
  апстриме, но провайдер целиком всё равно убран у нас (см. таблицу выше).
- После правок — финальный grep-проход по всем убранным идентификаторам
  (`discord`, `cascade`, `mango`, `crypto`, `crpt`, `games-direct`,
  `▶️ YouTube`) на предмет осиротевших ссылок в оставшемся файле — чисто,
  только сами объяснения в шапке файла.

### Механика API: второй нюанс сверх того, что описано выше

`POST /api/subscription-templates` создаёт новый именованный шаблон, но
**игнорирует** `encodedTemplateYaml`/`templateJson` из тела запроса — новый
шаблон создаётся с заглушкой Remnawave по умолчанию (`mode: global`,
`allow-lan: true`, generic fake-ip filter, без единого прокси/правила).
Реальный контент нужно заливать **отдельным** `PATCH /api/subscription-templates`
с `uuid` только что созданного шаблона — та же ручка и то же тело, что и для
правки уже существующих слотов (см. выше). Round-trip `GET` после `PATCH`
подтверждён побайтово (`hashlib`/прямое сравнение байтов — 42135 байт,
идентично файлу в этом репозитории).

Также обнаружилось ограничение на имя: `^[A-Za-z0-9_\s-]+$` — ни скобок, ни
запятых, только буквы/цифры/подчёркивания/дефисы/пробелы (400 с понятным
сообщением при нарушении).

### Текущий uuid и статус — АКТИВЕН на проде (2026-08-20)

```
uuid: 82c344fb-c672-4058-8131-a94366f2989b
name: dropweb-mihomo VPN-ProjectX trimmed
templateType: MIHOMO
```

Response Rule «Mihomo Clients» переключён на этот шаблон явно:

```json
{ "subscriptionTemplate": "dropweb-mihomo VPN-ProjectX trimmed" }
```

Применено через `PATCH /api/subscription-settings` — весь объект
`responseRules` (все 6 правил) отправлен целиком, изменено только поле
`responseModifications` у правила «Mihomo Clients», остальные 5 правил и
все прочие top-level поля (`customRemarks`, `customResponseHeaders`,
`hwidSettings` и т.д.) переданы как есть — тот же принцип «PATCH заменяет
объект целиком, не мёржит по ключам», что и в фиксе Happ/INCY выше, только
здесь объект на уровень выше (`subscription-settings`, а не
`customResponseHeaders` внутри него).

**Наступили на собственные грабли по пути** — CLAUDE.md инвариант №5 явно
требует `encoding='utf-8'` для любого инлайн-python на Windows; при первой
попытке PATCH это правило было нарушено (открывали JSON без явной
кодировки), и вся кириллица/эмодзи в `customRemarks`/`customResponseHeaders`
на проде на несколько минут превратилась в mojibake (`→` → `в†’` и т.п.).
Поймано сразу по ответу PATCH, исправлено повторным PATCH с правильной
кодировкой в течение той же сессии — сохранено здесь как ещё одно
подтверждение, почему это правило есть.

**Проверено на живой подписке**, не только round-trip GET настроек:
тестовый аккаунт `svc-transit-de` (тот же принцип, что и в разделе выше —
не реальный подписчик), `curl -A "clash-verge/v1.6.6" <ссылка>` — в ответе
структура `dropweb-mihomo` (`tls-fragment`, `x-anchors`), `discord`/
`games-direct` отсутствуют, узел подписки подставлен корректно.

Обратное переключение — то же поле у правила «Mihomo Clients» со значением
`"Default"` (имя исходного RoscomVPN-шаблона на этой инсталляции) либо
вообще без поля `responseModifications` (тогда снова берётся дефолт слота).
