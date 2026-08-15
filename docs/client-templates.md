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
| Clash Meta / Karing (regex `^(?:flclash\|flowvy\|murge\|mihomo\|prizrak-box\|koala-clash\|clash...)`) | Mihomo YAML | [`../configs/client-mihomo-ru.yaml`](../configs/client-mihomo-ru.yaml) | MIHOMO | ✅ Применено 2026-08-15 |
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
