# API, вебхуки и автоматизация

Как рулить всем хозяйством программно.

---

## 1. Что уже готово, а что писать самому

Прежде чем писать свой сервис — проверьте каталог [`awesome-remnawave`](https://github.com/remnawave/panel/blob/main/docs/awesome-remnawave.mdx). Там собраны решения сообщества, одобренные мейнтейнером:

| Категория | Что там есть |
|---|---|
| Telegram-боты | Управление пользователями, выдача подписок, статистика |
| Биллинг | Приём платежей, автопродление, тарифы |
| Автоустановка | Скрипты деплоя панели и нод, миграция с Marzban |
| Бэкапы | Автоматические дампы БД с отправкой в Telegram/S3 |
| Мониторинг | Экспортеры метрик, дашборды |
| Страницы подписки | Альтернативные шаблоны |

Своё имеет смысл писать, когда у вас специфичная бизнес-логика: интеграция с вашей учётной системой, нестандартные правила выдачи, свой интерфейс.

---

## 2. Быстрый старт

```bash
pip install -r api/requirements.txt
```

Ключ создаётся в панели: `Settings → API Keys`. Скоуп — минимально необходимый.

```python
import asyncio
from remnawave_client import Remnawave

async def main():
    async with Remnawave("https://panel.example.com", "ВАШ_ТОКЕН") as rw:
        report = await rw.nodes.health_report()
        print(report)

asyncio.run(main())
```

Первым делом прогоните сверку путей — Remnawave активно развивается, и ручки между версиями переезжают:

```bash
python api/remnawave_client.py --verify https://panel.example.com ТОКЕН
```

Если что-то отвечает 404 — правьте класс `Routes` в начале файла, сверяясь с [OpenAPI-спекой](https://docs.rw/api). Все пути собраны там намеренно, чтобы правка была в одном месте.

---

## 3. Типовые сценарии

### 3.1. Онбординг нового человека

```python
from remnawave_client import Remnawave, onboard_friend

async with Remnawave(URL, TOKEN) as rw:
    link = await onboard_friend(
        rw, "ivan",
        squad_name="EU",     # сквад с нодами FR/DE/NL
        gb=300,              # лимит трафика
        days=30,
        devices=3,           # HWID-лимит
    )
    print(link)   # https://sub.example.com/xxxxx
```

**Отдавайте именно ссылку подписки, а не сырой `vless://`.** Ссылку можно отозвать точечно (`revoke_subscription`), она отдаёт все профили сразу, и клиент сам переключается между ними при недоступности узла. Сырой URI живёт вечно и расходится по чатам.

### 3.2. Утёк ключ

```python
async with Remnawave(URL, TOKEN) as rw:
    user = await rw.users.get_by_username("ivan")
    await rw.users.revoke_subscription(user["uuid"])
```

Старая ссылка мертва, новая выдана, остальные пользователи не затронуты, на серверах менять ничего не надо.

### 3.3. Массовое продление

```python
async with Remnawave(URL, TOKEN) as rw:
    for u in await rw.users.list():
        if u["status"] == "ACTIVE":
            await rw.users.extend(u["uuid"], days=30)
```

### 3.4. Чистка неактивных

```python
from remnawave_client import cleanup_inactive

async with Remnawave(URL, TOKEN) as rw:
    # Сначала посмотреть, кого затронет
    victims = await cleanup_inactive(rw, days=60, dry_run=True)
    print(victims)

    # Потом применить
    await cleanup_inactive(rw, days=60, dry_run=False)
```

Меньше активных ключей — меньше поверхность утечки и ниже нагрузка на входную ноду.

### 3.5. Экстренная эвакуация входной ноды

Сценарий: российский IP выпал из белых списков или попал под ограничение.

```python
async with Remnawave(URL, TOKEN) as rw:
    hosts = await rw.hosts.list()
    primary = next(h for h in hosts if h["remark"] == "RU-Gate-Primary")
    backup  = next(h for h in hosts if h["remark"] == "RU-Gate-Backup")

    await rw.hosts.disable(primary["uuid"])
    await rw.hosts.enable(backup["uuid"])
```

Клиенты подхватят новый конфиг при следующем обновлении подписки. Ни одного сообщения в чат.

Для этого резервный хост должен быть заведён **заранее** — вместе с резервным VPS, доменом и сертификатом. Настраивать всё это в момент аварии поздно.

### 3.6. Контроль версий Xray

```python
async with Remnawave(URL, TOKEN) as rw:
    r = await rw.nodes.health_report()
    if r["version_mismatch"]:
        print(f"ВНИМАНИЕ: разные версии Xray: {r['xray_versions']}")
    if r["down"]:
        print(f"Не на связи: {r['down']}")
```

XHTTP в активной разработке — рассинхрон версий между нодами (и между сервером и клиентами) даёт сбои без внятных ошибок в логах. Проверяйте это регулярно; `scripts/90-healthcheck.sh` делает то же самое из bash.

---

## 4. Вебхуки

### Настройка

В `.env` панели:

```bash
WEBHOOK_ENABLED=true
WEBHOOK_URL=https://your-service.example.com/webhook
WEBHOOK_SECRET_HEADER=<длинный случайный секрет>
```

Запуск приёмника:

```bash
export WEBHOOK_SECRET=<тот же секрет>
export PANEL_URL=https://panel.example.com
export PANEL_TOKEN=<токен>
export TG_BOT_TOKEN=<токен бота>   # опционально
export TG_CHAT_ID=<chat id>        # опционально

uvicorn webhook_server:app --host 127.0.0.1 --port 8000
```

Обязательно за nginx с TLS. Подпись защищает от подделки, но не от прослушивания.

### Systemd-юнит

```ini
# /etc/systemd/system/rw-webhook.service
[Unit]
Description=Remnawave webhook receiver
After=network.target

[Service]
Type=simple
User=webhook
WorkingDirectory=/opt/rw-webhook
EnvironmentFile=/opt/rw-webhook/.env
ExecStart=/opt/rw-webhook/venv/bin/uvicorn webhook_server:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/rw-webhook

[Install]
WantedBy=multi-user.target
```

### События, которые стоит обрабатывать

| Событие | Зачем |
|---|---|
| `user.limited` / `bandwidth_usage_threshold_reached` | Исчерпан трафик. **Плюс детектор аномалий:** 300 ГБ за двое суток почти наверняка означает, что ключ разошёлся или через вас качают торренты — и то и другое бьёт по репутации белого IP |
| `user.expired` | Истёк срок — повод предложить продление |
| `user.first_connected` | Подтверждение, что человек успешно настроился |
| `node.connection_lost` | **Критично для RU-ноды**: клиенты не подключатся вообще. Для выходной — трафик перераспределится, но нужен разбор |
| `node.connection_restored` | Закрыть инцидент |

Важная деталь реализации: обработчик **не должен отдавать 500** при внутренней ошибке. Панель начнёт ретраить и завалит вас дублями. В `webhook_server.py` исключения ловятся и логируются, а наружу всегда идёт `{"ok": true}`.

---

## 5. Регулярные задачи

Через cron или APScheduler:

| Периодичность | Задача |
|---|---|
| Каждые 10 мин | `scripts/90-healthcheck.sh --notify` |
| Ежедневно | Бэкап БД панели (настроен установщиком) |
| Ежедневно | Отчёт по трафику и топ-потребителям |
| Еженедельно | `dpi-ch` по вашим подсетям → алерт при попадании в «подозрительные» |
| Еженедельно | Обновление geoip/geosite (настроено установщиком ноды) |
| Ежемесячно | `cleanup_inactive(days=60)` |

Пример регулярной проверки подсети:

```bash
# /etc/cron.weekly/check-subnets
#!/bin/bash
# Прогоняет dpi-ch и шлёт алерт, если ваш IP стал "подозрительным".
# Установка: https://github.com/hyperion-cs/dpi-checkers
dpi-ch --config /opt/dpi-ch/my-subnets.yaml --format json > /tmp/dpi.json
if jq -e '.results[] | select(.siberian == true)' /tmp/dpi.json >/dev/null; then
  curl -sS -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=⚠️ Ваша подсеть попала под ограничение. Проверьте dpi-ch и готовьте эвакуацию."
fi
```

---

## 6. Безопасность API

| Правило | Почему |
|---|---|
| Панель не должна быть публично доступна | Cloudflare Access, allow/deny по IP или доступ только через VPN |
| API-ключ с минимальным скоупом | Утечка ключа с полными правами = утечка всей базы пользователей |
| Ключи в переменных окружения или секрет-менеджере | Не в коде, не в git, не в истории shell |
| Ротация ключей раз в квартал | Стандартная гигиена |
| Rate limit на своём сервисе | Чтобы баг в цикле не завалил панель |
| Вебхук-приёмник только за TLS | Подпись ≠ шифрование |
| Отдельный системный пользователь для сервиса | Не root |
| Логи без персональных данных и без ключей | Логи утекают чаще, чем базы |

---

## 7. Если остаётесь на 3x-ui

`api/xui_orchestrator.py` — веерные операции по N панелям.

```python
import asyncio
from xui_orchestrator import Orchestrator, Panel

panels = [
    Panel("ru", "https://ru.example.com:2053/secret", "admin", "pass",
          inbound_id=1, public_host="vpn.example.ru",
          sni="vpn.example.ru", public_key="...", short_id="..."),
    Panel("de", "https://de.example.com:2053/secret", "admin", "pass", inbound_id=1),
]

async def main():
    async with Orchestrator(panels) as o:
        res = await o.add_user_everywhere("ivan", gb=200, days=30, devices=3)
        cid = res["_uuid"]["result"]
        links = await o.build_links(cid)
        for name, link in links.items():
            print(f"{name}: {link}")

asyncio.run(main())
```

### Обязательно: регулярный reconcile

Главная проблема ручной оркестрации — расхождение состояния. Если панель была недоступна в момент массовой операции, у неё другой набор пользователей, и узнать об этом можно только сверкой.

```python
async with Orchestrator(panels) as o:
    expected = {"ivan", "petr", "anna"}
    report = await o.reconcile(expected)
    for name, r in report.items():
        if r.get("ok") and not r["in_sync"]:
            print(f"{name}: не хватает {r['missing']}, лишние {r['extra']}")
```

Ставьте в cron ежедневно. Без этого схема тихо разъезжается в течение недель, и обнаруживается это по жалобам пользователей.

### Про учёт трафика в 3x-ui

`collect_traffic()` суммирует по всем панелям, но для транзитной схемы цифра **завышена примерно вдвое**: трафик учитывается и на входной RU-ноде, и на выходной. Считайте либо только по входной ноде, либо только по выходным — но не всё вместе.

---

## 8. Что стоит логировать

| Событие | Зачем |
|---|---|
| Создание/удаление пользователя, кем и когда | Аудит, разбор инцидентов |
| Отзыв подписки и причина | Понять, чей ключ утёк и как |
| Смена конфигурации нод | Откат при поломке |
| Аномалии трафика | Ранний сигнал о расползании ключа |
| Падения и восстановления нод | Статистика надёжности провайдеров |

Чего логировать **не** надо: содержимое трафика, посещённые домены, IP-адреса пользователей дольше необходимого. В конфигах `configs/` намеренно стоит `"access": "none"` и `dnsLog: false` — то, чего нет, невозможно ни утечь, ни изъять.
