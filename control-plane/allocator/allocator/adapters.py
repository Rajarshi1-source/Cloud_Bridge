"""The allocator's connections to the outside: cells over HTTPS through Cloudflare Access, Postgres."""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

import psycopg

from .core import Grant, Lease
from .cycle import CellUnreachable, StaleGrant

TIMEOUT_SECONDS = 5


class HttpCells:
    """Calls each cell's admin host. Cloudflare Access turns the service token into the JWT the cell checks."""

    def __init__(self, urls: dict[str, str], client_id: str, client_secret: str):
        self.urls = urls
        self.headers = {"CF-Access-Client-Id": client_id, "CF-Access-Client-Secret": client_secret}

    def _call(self, cell: str, path: str, body: dict | None = None) -> object:
        data = json.dumps(body).encode() if body is not None else None
        headers = {**self.headers, "Content-Type": "application/json"} if data else self.headers
        request = urllib.request.Request(self.urls[cell] + path, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                return json.load(response)
        except urllib.error.HTTPError as ex:
            if ex.code == 409:
                raise StaleGrant(ex.read().decode(errors="replace")[:300]) from ex
            raise CellUnreachable(f"{path} answered {ex.code}: {ex.read().decode(errors='replace')[:300]}") from ex
        except (OSError, ValueError) as ex:  # URLError and timeouts are OSError, a non-JSON body ValueError
            raise CellUnreachable(f"{path}: {ex}") from ex

    def report(self, cell: str) -> dict[str, Lease]:
        rows = self._call(cell, "/admin/leases/report")
        try:
            return {
                row["sku"]: Lease(
                    row["soldQty"], row["grantedQty"], row["leaseEpoch"], datetime.fromisoformat(row["expiresAt"])
                )
                for row in rows
            }
        except (KeyError, TypeError) as ex:
            raise CellUnreachable(f"report has an unexpected shape: {ex}") from ex

    def grant(self, grant: Grant) -> int:
        answer = self._call(
            grant.cell,
            "/admin/leases/grant",
            {
                "sku": grant.sku,
                "remainingQty": grant.remaining_qty,
                "reportedSold": grant.reported_sold,
                "epoch": grant.epoch,
                "expiresAt": grant.expires_at.isoformat(),
            },
        )
        try:
            return answer["grantedQty"]
        except (KeyError, TypeError) as ex:
            raise CellUnreachable(f"grant answer has an unexpected shape: {ex}") from ex


class PostgresStore:
    def __init__(self, dsn: str):
        self.conn = psycopg.connect(dsn, autocommit=True)
        self.conn.execute((Path(__file__).parent / "schema.sql").read_text())

    def seed_stock(self, stock: dict[str, int]) -> None:
        for sku, qty in stock.items():
            self.conn.execute(
                "INSERT INTO stock (sku, total_qty) VALUES (%s, %s) ON CONFLICT (sku) DO NOTHING", (sku, qty)
            )

    def stock(self) -> dict[str, int]:
        return dict(self.conn.execute("SELECT sku, total_qty FROM stock").fetchall())

    def last_lease(self, cell: str, sku: str) -> Lease | None:
        row = self.conn.execute(
            """SELECT reported_sold, granted_qty, epoch, expires_at FROM lease_grants
                WHERE cell_id = %s AND sku = %s ORDER BY epoch DESC LIMIT 1""",
            (cell, sku),
        ).fetchone()
        return Lease(*row) if row else None

    def record(self, grant: Grant, granted_total: int) -> None:
        self.conn.execute(
            """INSERT INTO lease_grants (cell_id, sku, epoch, granted_qty, expires_at, reported_sold)
               VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT (cell_id, sku, epoch) DO NOTHING""",
            (grant.cell, grant.sku, grant.epoch, granted_total, grant.expires_at, grant.reported_sold),
        )
