"""One allocation cycle: read every cell, work out the grants, send them, record what stuck."""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from .core import CellView, Config, Grant, Lease, clip, committed, overrun, plan

log = logging.getLogger("allocator")


class CellUnreachable(Exception):
    """The cell did not answer, or answered with something that isn't a usable report."""


class StaleGrant(Exception):
    """The cell already holds a newer epoch; its next report tells us the real one."""


class CellClient(Protocol):
    def report(self, cell: str) -> dict[str, Lease]: ...

    def grant(self, grant: Grant) -> int: ...


class Store(Protocol):
    def stock(self) -> dict[str, int]: ...

    def last_lease(self, cell: str, sku: str) -> Lease | None: ...

    def record(self, grant: Grant, granted_total: int) -> None: ...


@dataclass(frozen=True)
class CycleResult:
    applied: list[Grant]
    unreachable: list[str]


def run_cycle(
    weights: dict[str, int], client: CellClient, store: Store, now: datetime, cfg: Config = Config()
) -> CycleResult:
    reports: dict[str, dict[str, Lease]] = {}
    unreachable = []
    for cell in weights:
        try:
            reports[cell] = client.report(cell)
        except CellUnreachable as ex:
            unreachable.append(cell)
            log.warning("cell %s unreachable: %s", cell, ex)

    applied = []
    for sku, total in store.stock().items():
        views = []
        for cell, weight in weights.items():
            if cell in reports:
                # A cell with no row yet has simply never been granted this SKU. A store record with a
                # higher epoch than the report means its database went backwards: never reuse an epoch.
                reported = reports[cell].get(sku, Lease())
                known = store.last_lease(cell, sku)
                epoch = max(reported.epoch, known.epoch if known else 0)
                lease = Lease(reported.sold, reported.granted, epoch, reported.expires_at)
                views.append(CellView(cell, weight, True, lease))
            else:
                # None when we have no record of it: it may hold anything, so plan() grants nothing.
                views.append(CellView(cell, weight, False, store.last_lease(cell, sku)))
        applied.extend(_apply_sku(sku, total, views, client, store, now, cfg))
    return CycleResult(applied, unreachable)


def _apply_sku(
    sku: str, total: int, views: list[CellView], client: CellClient, store: Store, now: datetime, cfg: Config
) -> list[Grant]:
    over = overrun(total, views)
    if over:
        log.error("STOCK OVERRUN sku=%s sold %d more than stock %d", sku, over, total)
    grants = plan(sku, total, views, now, cfg)
    if not grants:
        if any(v.lease is None for v in views):
            log.warning("sku %s: no grants, an unreachable cell has no recorded lease", sku)
        return []
    held = {v.cell: committed(v.lease, now, cfg) for v in views}
    applied = []
    for planned in grants:
        grant = clip(planned, total, held)
        try:
            actual = client.grant(grant)
        except CellUnreachable as ex:
            # The POST may have landed even though we saw no answer, so assume the larger of the two.
            held[grant.cell] = max(held[grant.cell], grant.total)
            log.warning("grant to %s for %s not confirmed: %s", grant.cell, sku, ex)
        except StaleGrant as ex:
            log.warning("grant to %s for %s rejected as stale: %s", grant.cell, sku, ex)
        else:
            # What the cell says it now holds, not what we asked for: a cell that sold past the new
            # total while the grant travelled keeps its sales, and the next cell must leave room for them.
            held[grant.cell] = actual
            store.record(grant, actual)
            applied.append(grant)
    return applied
