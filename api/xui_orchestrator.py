"""
Оркестратор 3x-ui: синхронизация одного пользователя между N панелями.

Альтернативный путь для тех, кто разворачивает на 3x-ui вместо Remnawave
(основной путь этого проекта — см. README, DECISIONS.md ADR-0001;
подробности использования — docs/panel-comparison.md).

Проблема, которую он решает
───────────────────────────
3x-ui — монолит: панель и ядро в одном процессе, пользователи привязаны к
конкретному inbound на конкретном сервере. При 5 серверах создание одного
человека — это 5 ручных операций, ротация ключа — ещё 5, удаление — ещё 5.
На 100 пользователях это 500 операций на каждую массовую операцию.

Этот модуль превращает их в один вызов:

    import asyncio
    from xui_orchestrator import Orchestrator, Panel

    panels = [
        Panel("ru", "https://ru.example.com:2053/secretpath", "admin", "pass", inbound_id=1),
        Panel("de", "https://de.example.com:2053/secretpath", "admin", "pass", inbound_id=1),
        Panel("fr", "https://fr.example.com:2053/secretpath", "admin", "pass", inbound_id=1),
    ]

    async def main():
        async with Orchestrator(panels) as o:
            res = await o.add_user_everywhere("ivan", gb=200, days=30, devices=3)
            for name, r in res.items():
                print(name, "ok" if r["ok"] else r["error"])

    asyncio.run(main())

Особенности этого инструмента
─────────────────────────────
  • Нет единой страницы подписки — ссылки собираются вручную (см. build_links)
  • Трафик считается на каждом сервере отдельно, сквозной статистики нет
  • HWID-лимита нет, только limitIp (лимит одновременных IP — не то же самое)
  • Синхронизация состояния — по опросу, вебхуков нет
  • При недоступности одной панели во время массовой операции состояние
    расходится — обязательно вызывать reconcile() регулярно

    pip install httpx
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid as uuidlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import quote

import httpx

log = logging.getLogger("xui")
GB = 1024 ** 3


@dataclass
class Panel:
    """Одна инсталляция 3x-ui."""

    name: str
    base_url: str          # https://host:2053/secretpath  (без / на конце)
    username: str
    password: str
    inbound_id: int = 1

    # Параметры для сборки клиентской ссылки
    public_host: str = ""      # домен, который увидит клиент
    port: int = 443
    sni: str = ""
    public_key: str = ""
    short_id: str = ""
    xhttp_path: str = "/assets/media/stream"

    verify_ssl: bool = True
    _client: httpx.AsyncClient | None = field(default=None, repr=False, compare=False)

    def __post_init__(self) -> None:
        self.base_url = self.base_url.rstrip("/")
        if not self.public_host:
            self.public_host = self.base_url.split("://")[-1].split(":")[0].split("/")[0]
        if not self.sni:
            self.sni = self.public_host


class XuiError(RuntimeError):
    pass


class XuiClient:
    """Минимальный клиент 3x-ui API. Держит сессионную куку после логина."""

    def __init__(self, panel: Panel, timeout: float = 30.0):
        self.p = panel
        self._c = httpx.AsyncClient(
            base_url=panel.base_url,
            timeout=timeout,
            verify=panel.verify_ssl,
            follow_redirects=True,
        )
        self._authed = False

    async def login(self) -> None:
        r = await self._c.post(
            "/login",
            data={"username": self.p.username, "password": self.p.password},
        )
        if r.status_code != 200:
            raise XuiError(f"[{self.p.name}] логин: HTTP {r.status_code}")
        try:
            body = r.json()
        except Exception as exc:
            raise XuiError(f"[{self.p.name}] логин: неожиданный ответ") from exc
        if not body.get("success"):
            raise XuiError(f"[{self.p.name}] логин отклонён: {body.get('msg')}")
        self._authed = True
        log.debug("[%s] авторизован", self.p.name)

    async def _post(self, path: str, **kw: Any) -> dict:
        if not self._authed:
            await self.login()
        r = await self._c.post(path, **kw)
        if r.status_code == 401:          # кука протухла
            self._authed = False
            await self.login()
            r = await self._c.post(path, **kw)
        if r.status_code >= 400:
            raise XuiError(f"[{self.p.name}] {path}: HTTP {r.status_code}")
        return r.json()

    async def _get(self, path: str) -> dict:
        if not self._authed:
            await self.login()
        r = await self._c.get(path)
        if r.status_code == 401:
            self._authed = False
            await self.login()
            r = await self._c.get(path)
        if r.status_code >= 400:
            raise XuiError(f"[{self.p.name}] {path}: HTTP {r.status_code}")
        return r.json()

    # ── Инбаунды ──────────────────────────────────────────────────────────
    async def list_inbounds(self) -> list[dict]:
        return (await self._get("/panel/api/inbounds/list")).get("obj", []) or []

    async def get_inbound(self, inbound_id: int) -> dict:
        return (await self._get(f"/panel/api/inbounds/get/{inbound_id}")).get("obj", {})

    # ── Клиенты ───────────────────────────────────────────────────────────
    async def add_client(
        self,
        email: str,
        client_uuid: str,
        *,
        gb: float = 0,
        days: int = 30,
        limit_ip: int = 3,
        flow: str = "",
        sub_id: str = "",
    ) -> dict:
        expiry_ms = (
            int((datetime.now(timezone.utc) + timedelta(days=days)).timestamp() * 1000)
            if days > 0 else 0
        )
        client = {
            "id": client_uuid,
            "flow": flow,
            "email": email,
            "limitIp": limit_ip,
            "totalGB": int(gb * GB),
            "expiryTime": expiry_ms,
            "enable": True,
            "tgId": "",
            "subId": sub_id or email,
            "reset": 0,
        }
        return await self._post(
            "/panel/api/inbounds/addClient",
            data={
                "id": self.p.inbound_id,
                "settings": json.dumps({"clients": [client]}),
            },
        )

    async def update_client(self, client_uuid: str, settings: dict) -> dict:
        return await self._post(
            f"/panel/api/inbounds/updateClient/{client_uuid}",
            data={"id": self.p.inbound_id, "settings": json.dumps({"clients": [settings]})},
        )

    async def delete_client(self, client_uuid: str) -> dict:
        return await self._post(
            f"/panel/api/inbounds/{self.p.inbound_id}/delClient/{client_uuid}"
        )

    async def client_traffic(self, email: str) -> dict:
        return (await self._get(f"/panel/api/inbounds/getClientTraffics/{email}")).get("obj", {})

    async def reset_client_traffic(self, email: str) -> dict:
        return await self._post(
            f"/panel/api/inbounds/{self.p.inbound_id}/resetClientTraffic/{email}"
        )

    async def online_clients(self) -> list[str]:
        return (await self._post("/panel/api/inbounds/onlines")).get("obj", []) or []

    def build_link(self, client_uuid: str, label: str = "") -> str:
        """Собирает vless:// ссылку с обязательными анти-ТСПУ параметрами."""
        extra = quote(json.dumps(
            {
                "xPaddingBytes": "100-1000",
                "xmux": {"maxConnections": "2-3", "maxConcurrency": 0},
            },
            separators=(",", ":"),
        ), safe="")
        return (
            f"vless://{client_uuid}@{self.p.public_host}:{self.p.port}"
            f"?type=xhttp&security=reality"
            f"&sni={self.p.sni}"
            f"&fp=firefox"                       # НЕ chrome — он в чёрном списке
            f"&pbk={self.p.public_key}"
            f"&sid={self.p.short_id}"
            f"&path={quote(self.p.xhttp_path, safe='')}"
            f"&mode=auto"
            f"&extra={extra}"
            f"#{quote(label or self.p.name)}"
        )

    async def aclose(self) -> None:
        await self._c.aclose()


class Orchestrator:
    """Веерные операции по всем панелям сразу."""

    def __init__(self, panels: list[Panel]):
        self.clients = {p.name: XuiClient(p) for p in panels}

    async def __aenter__(self) -> "Orchestrator":
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await asyncio.gather(*(c.aclose() for c in self.clients.values()),
                             return_exceptions=True)

    async def _fan_out(self, coro_factory) -> dict[str, dict]:
        async def run(name: str, client: XuiClient) -> tuple[str, dict]:
            try:
                res = await coro_factory(client)
                return name, {"ok": True, "result": res}
            except Exception as e:  # noqa: BLE001
                log.error("[%s] %s: %s", name, type(e).__name__, e)
                return name, {"ok": False, "error": f"{type(e).__name__}: {e}"}

        pairs = await asyncio.gather(*(run(n, c) for n, c in self.clients.items()))
        return dict(pairs)

    async def add_user_everywhere(
        self,
        email: str,
        *,
        gb: float = 0,
        days: int = 30,
        devices: int = 3,
        client_uuid: str | None = None,
    ) -> dict[str, dict]:
        """
        Создаёт одного пользователя на всех панелях с ОДНИМ И ТЕМ ЖЕ UUID.

        Единый UUID критичен: он позволяет отдать человеку один набор
        профилей, между которыми клиент переключается сам при недоступности
        одного из узлов.
        """
        cid = client_uuid or str(uuidlib.uuid4())
        res = await self._fan_out(
            lambda c: c.add_client(email, cid, gb=gb, days=days, limit_ip=devices)
        )
        res["_uuid"] = {"ok": True, "result": cid}
        return res

    async def delete_user_everywhere(self, client_uuid: str) -> dict[str, dict]:
        return await self._fan_out(lambda c: c.delete_client(client_uuid))

    async def reset_traffic_everywhere(self, email: str) -> dict[str, dict]:
        return await self._fan_out(lambda c: c.reset_client_traffic(email))

    async def collect_traffic(self, email: str) -> dict[str, Any]:
        """
        Суммирует трафик пользователя по всем панелям.

        В 3x-ui нет сквозного учёта — считаем сами. Помните: трафик через
        RU-ноду учтётся и на ней, и на выходной, поэтому суммарная цифра
        завышена примерно вдвое для транзитных схем.
        """
        res = await self._fan_out(lambda c: c.client_traffic(email))
        total_up = total_down = 0
        per_panel: dict[str, Any] = {}
        for name, r in res.items():
            if not r["ok"]:
                per_panel[name] = {"error": r["error"]}
                continue
            obj = r["result"] or {}
            up, down = int(obj.get("up", 0)), int(obj.get("down", 0))
            total_up += up
            total_down += down
            per_panel[name] = {"up_gb": round(up / GB, 2), "down_gb": round(down / GB, 2)}
        return {
            "email": email,
            "total_gb": round((total_up + total_down) / GB, 2),
            "per_panel": per_panel,
            "_note": "для транзитных схем суммарная цифра завышена: трафик считается и на входе, и на выходе",
        }

    async def build_links(self, client_uuid: str) -> dict[str, str]:
        """Ссылки на все узлы — их и складывают в подписку."""
        return {
            name: c.build_link(client_uuid, label=f"{name.upper()}")
            for name, c in self.clients.items()
        }

    async def reconcile(self, expected_emails: set[str]) -> dict[str, dict]:
        """
        Сверяет фактическое состояние панелей с ожидаемым.

        Обязательная процедура при ручной оркестрации: если панель была
        недоступна в момент массовой операции, её состояние разошлось,
        и узнать об этом можно только сверкой.
        """
        report: dict[str, dict] = {}
        for name, client in self.clients.items():
            try:
                inbound = await client.get_inbound(client.p.inbound_id)
                settings = json.loads(inbound.get("settings", "{}"))
                actual = {c.get("email") for c in settings.get("clients", [])}
                report[name] = {
                    "ok": True,
                    "missing": sorted(expected_emails - actual),
                    "extra": sorted(actual - expected_emails),
                    "in_sync": actual == expected_emails,
                }
            except Exception as e:  # noqa: BLE001
                report[name] = {"ok": False, "error": f"{type(e).__name__}: {e}"}
        return report

    async def health(self) -> dict[str, dict]:
        """Живы ли панели и сколько клиентов онлайн."""
        async def probe(c: XuiClient) -> dict:
            inbounds = await c.list_inbounds()
            online = await c.online_clients()
            return {"inbounds": len(inbounds), "online": len(online)}

        return await self._fan_out(probe)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    print(__doc__)
