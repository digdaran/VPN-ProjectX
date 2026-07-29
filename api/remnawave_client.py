"""
Асинхронный клиент Remnawave API.

Заготовка под самописный оркестратор: пользователи, ноды, сквады, хосты,
статистика, подписки.

    pip install httpx

    import asyncio
    from remnawave_client import Remnawave

    async def main():
        async with Remnawave("https://panel.example.com", "TOKEN") as rw:
            u = await rw.users.create(
                username="ivan",
                traffic_limit_gb=200,
                expire_days=30,
                squad_uuids=["<uuid сквада с нужными нодами>"],
                hwid_device_limit=3,
            )
            print(u["subscriptionUrl"])

    asyncio.run(main())

ВАЖНО про пути эндпоинтов
─────────────────────────
Remnawave активно развивается, и пути ручек между мажорными версиями
меняются. Актуальная спека: https://docs.rw/api (OpenAPI).
Все пути собраны в классе `Routes` — если что-то отвалилось с 404,
правьте там, а не по всему файлу.

Быстрая сверка вашей версии со спекой:
    python remnawave_client.py --verify https://panel.example.com TOKEN
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

import httpx

log = logging.getLogger("remnawave")

GB = 1024 ** 3


class RemnawaveError(RuntimeError):
    """Ошибка API. Содержит статус и тело ответа."""

    def __init__(self, status: int, body: Any, method: str = "", path: str = ""):
        self.status = status
        self.body = body
        where = f" [{method} {path}]" if path else ""
        super().__init__(f"Remnawave API {status}{where}: {body}")


class Routes:
    """Все пути в одном месте — сверяйте с https://docs.rw/api при обновлении."""

    # Пользователи
    USERS = "/api/users"
    USER = "/api/users/{uuid}"
    USER_BY_USERNAME = "/api/users/by-username/{username}"
    USER_ENABLE = "/api/users/{uuid}/actions/enable"
    USER_DISABLE = "/api/users/{uuid}/actions/disable"
    USER_RESET_TRAFFIC = "/api/users/{uuid}/actions/reset-traffic"
    USER_REVOKE_SUB = "/api/users/{uuid}/actions/revoke"

    # Ноды
    NODES = "/api/nodes"
    NODE = "/api/nodes/{uuid}"
    NODE_ENABLE = "/api/nodes/{uuid}/actions/enable"
    NODE_DISABLE = "/api/nodes/{uuid}/actions/disable"
    NODE_RESTART = "/api/nodes/{uuid}/actions/restart"
    NODES_RESTART_ALL = "/api/nodes/actions/restart-all"
    NODES_USAGE = "/api/nodes/usage/range"

    # Сквады (группы нод/инбаундов, к которым привязывается пользователь)
    SQUADS = "/api/internal-squads"
    SQUAD = "/api/internal-squads/{uuid}"

    # Хосты (то, что видит клиент в подписке)
    HOSTS = "/api/hosts"
    HOST = "/api/hosts/{uuid}"

    # Инбаунды и конфиг-профили
    INBOUNDS = "/api/inbounds"
    CONFIG_PROFILES = "/api/config-profiles"

    # Система
    STATS = "/api/system/stats"
    BANDWIDTH = "/api/system/stats/bandwidth"
    HEALTH = "/api/system/health"

    # HWID-устройства
    HWID_DEVICES = "/api/hwid/devices/{uuid}"


@dataclass(slots=True)
class _Ctx:
    client: httpx.AsyncClient
    base_url: str


class _Section:
    def __init__(self, ctx: _Ctx, request):
        self._ctx = ctx
        self._req = request


# ─────────────────────────────────────────────────────────────────────────────
# Пользователи
# ─────────────────────────────────────────────────────────────────────────────
class Users(_Section):
    async def list(
        self,
        *,
        size: int = 100,
        start: int = 0,
        search: str | None = None,
    ) -> list[dict]:
        """Постранично выгружает всех пользователей."""
        out: list[dict] = []
        while True:
            params: dict[str, Any] = {"size": size, "start": start}
            if search:
                params["search"] = search
            data = await self._req("GET", Routes.USERS, params=params)
            batch = data.get("users", data if isinstance(data, list) else [])
            out.extend(batch)
            total = data.get("total", len(out)) if isinstance(data, dict) else len(out)
            start += size
            if len(batch) < size or start >= total:
                break
        return out

    async def get(self, uuid: str) -> dict:
        return await self._req("GET", Routes.USER.format(uuid=uuid))

    async def get_by_username(self, username: str) -> dict:
        return await self._req("GET", Routes.USER_BY_USERNAME.format(username=username))

    async def create(
        self,
        username: str,
        *,
        traffic_limit_gb: float = 0,
        expire_days: int | None = 30,
        expire_at: datetime | None = None,
        squad_uuids: Iterable[str] = (),
        hwid_device_limit: int | None = 3,
        traffic_strategy: str = "MONTH",
        description: str = "",
        telegram_id: int | None = None,
        tag: str | None = None,
    ) -> dict:
        """
        Создаёт пользователя.

        traffic_limit_gb=0 — безлимит. Для раздачи знакомым лучше ставить
        осмысленный лимит: он отсекает того, кто решит качать через вас
        медиатеку, и тем самым бережёт репутацию белого IP.

        hwid_device_limit — единственная реальная защита от расползания
        ключа по чатам. Рекомендую 3–5.

        traffic_strategy: NO_RESET | DAY | WEEK | MONTH
        """
        if expire_at is None:
            days = expire_days if expire_days is not None else 3650
            expire_at = datetime.now(timezone.utc) + timedelta(days=days)

        payload: dict[str, Any] = {
            "username": username,
            "status": "ACTIVE",
            "trafficLimitBytes": int(traffic_limit_gb * GB),
            "trafficLimitStrategy": traffic_strategy,
            "expireAt": expire_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "description": description,
            "activeInternalSquads": list(squad_uuids),
        }
        if hwid_device_limit is not None:
            payload["hwidDeviceLimit"] = hwid_device_limit
        if telegram_id is not None:
            payload["telegramId"] = telegram_id
        if tag:
            payload["tag"] = tag

        return await self._req("POST", Routes.USERS, json=payload)

    async def update(self, uuid: str, **fields: Any) -> dict:
        """
        Частичное обновление. Поля — как в API:
        status, trafficLimitBytes, expireAt, activeInternalSquads,
        hwidDeviceLimit, description, tag.
        """
        return await self._req("PATCH", Routes.USERS, json={"uuid": uuid, **fields})

    async def delete(self, uuid: str) -> dict:
        return await self._req("DELETE", Routes.USER.format(uuid=uuid))

    async def enable(self, uuid: str) -> dict:
        return await self._req("POST", Routes.USER_ENABLE.format(uuid=uuid))

    async def disable(self, uuid: str) -> dict:
        return await self._req("POST", Routes.USER_DISABLE.format(uuid=uuid))

    async def reset_traffic(self, uuid: str) -> dict:
        return await self._req("POST", Routes.USER_RESET_TRAFFIC.format(uuid=uuid))

    async def revoke_subscription(self, uuid: str) -> dict:
        """
        Отзывает ссылку подписки и выдаёт новую.

        Ровно то, что нужно, когда чей-то ключ утёк: остальные пользователи
        не затронуты, менять ничего на серверах не надо.
        """
        return await self._req("POST", Routes.USER_REVOKE_SUB.format(uuid=uuid))

    async def extend(self, uuid: str, days: int) -> dict:
        """Продлевает подписку на N дней от текущей даты окончания."""
        user = await self.get(uuid)
        cur_raw = (user.get("expireAt") or "").replace("Z", "+00:00")
        try:
            cur = datetime.fromisoformat(cur_raw)
        except ValueError:
            cur = datetime.now(timezone.utc)
        base = max(cur, datetime.now(timezone.utc))
        new = base + timedelta(days=days)
        return await self.update(
            uuid,
            expireAt=new.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            status="ACTIVE",
        )

    async def devices(self, uuid: str) -> dict:
        """Список HWID-устройств пользователя."""
        return await self._req("GET", Routes.HWID_DEVICES.format(uuid=uuid))


# ─────────────────────────────────────────────────────────────────────────────
# Ноды
# ─────────────────────────────────────────────────────────────────────────────
class Nodes(_Section):
    async def list(self) -> list[dict]:
        data = await self._req("GET", Routes.NODES)
        return data if isinstance(data, list) else data.get("nodes", [])

    async def get(self, uuid: str) -> dict:
        return await self._req("GET", Routes.NODE.format(uuid=uuid))

    async def enable(self, uuid: str) -> dict:
        return await self._req("POST", Routes.NODE_ENABLE.format(uuid=uuid))

    async def disable(self, uuid: str) -> dict:
        return await self._req("POST", Routes.NODE_DISABLE.format(uuid=uuid))

    async def restart(self, uuid: str) -> dict:
        return await self._req("POST", Routes.NODE_RESTART.format(uuid=uuid))

    async def restart_all(self) -> dict:
        return await self._req("POST", Routes.NODES_RESTART_ALL)

    async def health_report(self) -> dict:
        """
        Сводка состояния всех нод + проверка единства версии Xray.

        Разные версии ядра на нодах — реальная проблема: XHTTP в активной
        разработке, и рассинхрон даёт сбои без внятных ошибок в логах.
        """
        nodes = await self.list()
        connected = [n for n in nodes if n.get("isConnected")]
        down = [n for n in nodes if not n.get("isConnected") and not n.get("isDisabled")]
        versions = {n.get("xrayVersion") for n in connected if n.get("xrayVersion")}
        return {
            "total": len(nodes),
            "connected": len(connected),
            "down": [n.get("name") for n in down],
            "xray_versions": sorted(v for v in versions if v),
            "version_mismatch": len(versions) > 1,
        }


# ─────────────────────────────────────────────────────────────────────────────
# Сквады, хосты, система
# ─────────────────────────────────────────────────────────────────────────────
class Squads(_Section):
    async def list(self) -> list[dict]:
        data = await self._req("GET", Routes.SQUADS)
        return data if isinstance(data, list) else data.get("internalSquads", [])

    async def get(self, uuid: str) -> dict:
        return await self._req("GET", Routes.SQUAD.format(uuid=uuid))

    async def by_name(self, name: str) -> dict | None:
        for s in await self.list():
            if s.get("name") == name:
                return s
        return None


class Hosts(_Section):
    async def list(self) -> list[dict]:
        data = await self._req("GET", Routes.HOSTS)
        return data if isinstance(data, list) else data.get("hosts", [])

    async def enable(self, uuid: str) -> dict:
        return await self._req("PATCH", Routes.HOSTS, json={"uuid": uuid, "isDisabled": False})

    async def disable(self, uuid: str) -> dict:
        """
        Выключает хост — он пропадает из подписок у всех пользователей.

        Механизм быстрой эвакуации: если IP входной ноды сгорел, выключаете
        соответствующий хост, включаете резервный — клиенты подхватывают
        новый конфиг при следующем обновлении подписки. Без рассылок.
        """
        return await self._req("PATCH", Routes.HOSTS, json={"uuid": uuid, "isDisabled": True})


class System(_Section):
    async def stats(self) -> dict:
        return await self._req("GET", Routes.STATS)

    async def bandwidth(self) -> dict:
        return await self._req("GET", Routes.BANDWIDTH)

    async def health(self) -> dict:
        return await self._req("GET", Routes.HEALTH)


# ─────────────────────────────────────────────────────────────────────────────
# Клиент
# ─────────────────────────────────────────────────────────────────────────────
class Remnawave:
    def __init__(
        self,
        base_url: str,
        token: str,
        *,
        timeout: float = 30.0,
        retries: int = 3,
        verify_ssl: bool = True,
        extra_headers: dict[str, str] | None = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.retries = retries
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            # Если панель спрятана за Cloudflare Access или реверс-прокси
            # с проверкой Host — эти заголовки часто требуются:
            "X-Forwarded-For": "127.0.0.1",
            "X-Forwarded-Proto": "https",
        }
        if extra_headers:
            headers.update(extra_headers)

        self._client = httpx.AsyncClient(
            base_url=self.base_url,
            headers=headers,
            timeout=timeout,
            verify=verify_ssl,
            follow_redirects=True,
        )
        ctx = _Ctx(self._client, self.base_url)
        self.users = Users(ctx, self._request)
        self.nodes = Nodes(ctx, self._request)
        self.squads = Squads(ctx, self._request)
        self.hosts = Hosts(ctx, self._request)
        self.system = System(ctx, self._request)

    async def _request(self, method: str, path: str, **kw: Any) -> Any:
        last: Exception | None = None
        for attempt in range(self.retries):
            try:
                r = await self._client.request(method, path, **kw)
            except httpx.TransportError as e:
                last = e
                if attempt < self.retries - 1:
                    await asyncio.sleep(2 ** attempt)
                    continue
                raise

            if r.status_code == 429:  # rate limit
                wait = float(r.headers.get("Retry-After", 2 ** attempt))
                log.warning("429 от панели, ждём %.1fs", wait)
                await asyncio.sleep(wait)
                continue

            if r.status_code >= 500 and attempt < self.retries - 1:
                await asyncio.sleep(2 ** attempt)
                continue

            if r.status_code >= 400:
                try:
                    body = r.json()
                except Exception:
                    body = r.text[:500]
                raise RemnawaveError(r.status_code, body, method, path)

            if not r.content:
                return {}
            data = r.json()
            # Remnawave заворачивает полезную нагрузку в {"response": ...}
            return data.get("response", data) if isinstance(data, dict) else data

        raise last or RuntimeError("Запрос не выполнен")

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> "Remnawave":
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.aclose()


# ─────────────────────────────────────────────────────────────────────────────
# Готовые сценарии
# ─────────────────────────────────────────────────────────────────────────────
async def onboard_friend(
    rw: Remnawave,
    username: str,
    *,
    squad_name: str = "default",
    gb: float = 300,
    days: int = 30,
    devices: int = 3,
) -> str:
    """
    Полный онбординг: находит сквад по имени, создаёт пользователя,
    возвращает ссылку подписки.

    Именно ссылку и отдавайте человеку — не сырой vless://. Ссылку можно
    отозвать точечно, а сырой URI живёт вечно и расходится по чатам.
    """
    squad = await rw.squads.by_name(squad_name)
    if not squad:
        available = [s.get("name") for s in await rw.squads.list()]
        raise ValueError(f"Сквад '{squad_name}' не найден. Доступны: {available}")

    user = await rw.users.create(
        username=username,
        traffic_limit_gb=gb,
        expire_days=days,
        squad_uuids=[squad["uuid"]],
        hwid_device_limit=devices,
        description=f"создан {datetime.now(timezone.utc):%Y-%m-%d}",
    )
    return user.get("subscriptionUrl", "")


async def cleanup_inactive(rw: Remnawave, days: int = 60, dry_run: bool = True) -> list[str]:
    """
    Отключает тех, кто не заходил дольше N дней.

    Меньше активных ключей — меньше поверхность утечки и ниже нагрузка
    на входную ноду.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    touched: list[str] = []
    for u in await rw.users.list():
        raw = u.get("onlineAt") or u.get("subLastOpenedAt")
        if not raw or u.get("status") != "ACTIVE":
            continue
        try:
            seen = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            continue
        if seen < cutoff:
            touched.append(u["username"])
            if not dry_run:
                await rw.users.disable(u["uuid"])
    return touched


async def verify_routes(base_url: str, token: str) -> None:
    """Простукивает основные ручки — быстрый способ поймать смену путей API."""
    async with Remnawave(base_url, token) as rw:
        checks = [
            ("система/статистика", rw.system.stats()),
            ("ноды", rw.nodes.list()),
            ("сквады", rw.squads.list()),
            ("хосты", rw.hosts.list()),
            ("пользователи", rw.users.list(size=1)),
        ]
        for name, coro in checks:
            try:
                await coro
                print(f"  ✓ {name}")
            except RemnawaveError as e:
                print(f"  ✗ {name} → {e.status}. Поправьте путь в классе Routes (см. https://docs.rw/api)")
            except Exception as e:  # noqa: BLE001
                print(f"  ✗ {name} → {type(e).__name__}: {e}")


if __name__ == "__main__":
    import sys

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    if len(sys.argv) >= 4 and sys.argv[1] == "--verify":
        print("Проверка эндпоинтов:")
        asyncio.run(verify_routes(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__)
        print("Проверить пути API:")
        print("  python remnawave_client.py --verify https://panel.example.com TOKEN")
