"""
Приёмник вебхуков Remnawave.

Панель шлёт сюда события по пользователям и нодам. Обработчики ниже —
заготовки: подставьте свою логику уведомлений, биллинга, автопродления.

    pip install fastapi uvicorn httpx
    export WEBHOOK_SECRET=...   # значение WEBHOOK_SECRET_HEADER из .env панели
    export PANEL_URL=https://panel.example.com
    export PANEL_TOKEN=...
    export TG_BOT_TOKEN=...     # опционально
    export TG_CHAT_ID=...       # опционально
    uvicorn webhook_server:app --host 127.0.0.1 --port 8000

Ставьте за nginx с TLS. Наружу голым HTTP не выставляйте: подпись защищает
от подделки, но не от прослушивания.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException, Request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("webhook")

WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "")
PANEL_URL = os.getenv("PANEL_URL", "").rstrip("/")
PANEL_TOKEN = os.getenv("PANEL_TOKEN", "")
TG_BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")
TG_CHAT_ID = os.getenv("TG_CHAT_ID", "")

app = FastAPI(title="Remnawave webhook receiver", docs_url=None, redoc_url=None)


# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────
def verify_signature(body: bytes, signature: str) -> bool:
    """
    HMAC-SHA256 по сырому телу запроса.

    Сравнение обязательно через compare_digest: обычное == уязвимо к
    тайминг-атаке.
    """
    if not WEBHOOK_SECRET:
        log.warning("WEBHOOK_SECRET не задан — проверка подписи ОТКЛЮЧЕНА")
        return True
    expected = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, (signature or "").strip())


async def notify(text: str) -> None:
    if not (TG_BOT_TOKEN and TG_CHAT_ID):
        log.info("NOTIFY: %s", text)
        return
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            await c.post(
                f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage",
                json={"chat_id": TG_CHAT_ID, "text": text, "parse_mode": "HTML"},
            )
    except Exception as e:  # noqa: BLE001
        log.error("Telegram: %s", e)


async def panel_call(method: str, path: str, **kw: Any) -> dict:
    if not (PANEL_URL and PANEL_TOKEN):
        raise RuntimeError("PANEL_URL / PANEL_TOKEN не заданы")
    async with httpx.AsyncClient(
        base_url=PANEL_URL,
        headers={"Authorization": f"Bearer {PANEL_TOKEN}"},
        timeout=30,
    ) as c:
        r = await c.request(method, path, **kw)
        r.raise_for_status()
        return r.json() if r.content else {}


# ─────────────────────────────────────────────────────────────────────────────
# Обработчики событий
# ─────────────────────────────────────────────────────────────────────────────
async def on_user_traffic_reached(d: dict) -> None:
    """
    Пользователь выбрал лимит трафика.

    Здесь же ловятся аномалии: если кто-то выбрал 300 ГБ за двое суток —
    почти наверняка ключ разошёлся или через вас качают торренты в обход
    блокировки. И то и другое бьёт по репутации белого IP.
    """
    user = d.get("username", "?")
    used_gb = round(int(d.get("usedTrafficBytes", 0)) / 1024 ** 3, 1)
    await notify(f"📊 <b>{user}</b> исчерпал лимит трафика ({used_gb} ГБ)")


async def on_user_expired(d: dict) -> None:
    await notify(f"⏰ <b>{d.get('username', '?')}</b> — истёк срок подписки")


async def on_user_first_connected(d: dict) -> None:
    await notify(f"👋 <b>{d.get('username', '?')}</b> подключился впервые")


async def on_node_disconnected(d: dict) -> None:
    """
    Нода отвалилась.

    Если отвалилась RU-входная — это авария: клиенты не подключатся вообще.
    Если выходная — трафик перераспределится, но нужен разбор.
    """
    name = d.get("name", "?")
    err = d.get("lastStatusMessage", "")
    await notify(f"🔴 Нода <b>{name}</b> отключилась\n<code>{err}</code>")


async def on_node_connected(d: dict) -> None:
    await notify(f"🟢 Нода <b>{d.get('name', '?')}</b> снова на связи")


async def on_node_traffic_notify(d: dict) -> None:
    await notify(
        f"📈 Нода <b>{d.get('name', '?')}</b>: достигнут порог трафика "
        f"({d.get('trafficUsedBytes', 0)} байт)"
    )


HANDLERS = {
    "user.expired": on_user_expired,
    "user.limited": on_user_traffic_reached,
    "user.bandwidth_usage_threshold_reached": on_user_traffic_reached,
    "user.first_connected": on_user_first_connected,
    "node.connection_lost": on_node_disconnected,
    "node.disconnected": on_node_disconnected,
    "node.connection_restored": on_node_connected,
    "node.connected": on_node_connected,
    "node.traffic_notify": on_node_traffic_notify,
}


# ─────────────────────────────────────────────────────────────────────────────
# Роуты
# ─────────────────────────────────────────────────────────────────────────────
@app.post("/webhook")
async def webhook(
    request: Request,
    x_remnawave_signature: str = Header(default=""),
) -> dict:
    body = await request.body()

    if not verify_signature(body, x_remnawave_signature):
        log.warning("Отклонён вебхук с некорректной подписью от %s",
                    request.client.host if request.client else "?")
        raise HTTPException(status_code=401, detail="bad signature")

    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="malformed json")

    event = payload.get("event", "")
    data = payload.get("data", {}) or {}
    log.info("event=%s user=%s node=%s", event, data.get("username"), data.get("name"))

    handler = HANDLERS.get(event)
    if handler:
        try:
            await handler(data)
        except Exception as e:  # noqa: BLE001
            # Не отдаём 500: панель начнёт ретраить и завалит нас дублями
            log.exception("Обработчик %s упал: %s", event, e)
    else:
        log.debug("Событие без обработчика: %s", event)

    return {"ok": True}


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    if not WEBHOOK_SECRET:
        log.warning("WEBHOOK_SECRET пуст — запускать так можно только локально")
    uvicorn.run(app, host="127.0.0.1", port=8000)
