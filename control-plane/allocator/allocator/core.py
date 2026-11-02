"""The lease arithmetic, with no I/O: what each cell may sell next, given what is known about all cells.

The invariant is that the sum over cells of what each cell may ever have sold stays within stock.
A cell's lease is a running total (sold so far + what it may still sell), so "committed" below is the
number of units a cell could have sold by the time it next hears from us.

Two things make a plain floor(remaining x weight x 0.9) unsafe on its own, and both are handled here:
  - Grants reach cells one at a time. While cell B's bigger lease is live, cell A may still hold its
    old one. So shrinks are sent first, and every grant is clipped against what the others hold now
    (`clip`), with the clip following what each POST reports back.
  - A cell keeps selling between our report and our grant. Grants carry the sold figure they were
    computed from, and the cell builds its total from that, so those sales come out of the new grant.

One limit remains, by design of the plan (Rev 2 section 23.3): after expires_at + margin, a cell we cannot
reach counts as having sold only what it last reported, so its unsold quantity can go elsewhere. If it
actually sold more before its lease ran out (the allocator was cut off, its customers were not), the
total can exceed stock by those sales. `overrun` makes that visible when the cell returns.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from math import floor

SAFETY_FACTOR_TENTHS = 9  # grant 90% of what is left; the rest absorbs sales racing a report


@dataclass(frozen=True)
class Config:
    lease_ttl: timedelta = timedelta(minutes=15)
    regrant_margin: timedelta = timedelta(seconds=60)


@dataclass(frozen=True)
class Lease:
    """A cell's lease for one SKU, as last known. Zero values mean it has never held one."""

    sold: int = 0
    granted: int = 0
    epoch: int = 0
    expires_at: datetime | None = None


@dataclass(frozen=True)
class CellView:
    cell: str
    weight_percent: int
    reachable: bool
    lease: Lease | None  # None: unreachable and never recorded, so what it holds is unknown


@dataclass(frozen=True)
class Grant:
    cell: str
    sku: str
    remaining_qty: int
    reported_sold: int
    epoch: int
    expires_at: datetime

    @property
    def total(self) -> int:
        return self.reported_sold + self.remaining_qty


def committed(lease: Lease, now: datetime, cfg: Config) -> int:
    """Units this cell could have sold. Its whole lease counts until expiry plus the clock-skew margin."""
    if lease.expires_at is not None and now < lease.expires_at + cfg.regrant_margin:
        return max(lease.granted, lease.sold)
    return lease.sold


def remaining_stock(total: int, views: list[CellView], now: datetime, cfg: Config) -> int:
    """What is left to share out: stock minus sales, minus everything unreachable cells may still sell."""
    left = total
    for view in views:
        left -= view.lease.sold if view.reachable else committed(view.lease, now, cfg)
    return max(left, 0)


def overrun(total: int, views: list[CellView]) -> int:
    """Units sold beyond stock according to the latest reports. Nonzero means the invariant was broken."""
    return max(sum(v.lease.sold for v in views if v.lease is not None) - total, 0)


def plan(sku: str, total: int, views: list[CellView], now: datetime, cfg: Config) -> list[Grant]:
    """This cycle's grants for one SKU, shrinks first. Empty when an unknown cell makes it unsafe to grant."""
    if any(v.lease is None for v in views):
        return []
    left = remaining_stock(total, views, now, cfg)
    grants = []
    for view in views:
        if not view.reachable:
            continue
        lease = view.lease
        # Integer arithmetic: floats could round a grant up past the invariant.
        share = floor(left * view.weight_percent * SAFETY_FACTOR_TENTHS / 1000)
        grants.append(Grant(view.cell, sku, share, lease.sold, lease.epoch + 1, now + cfg.lease_ttl))
    by_cell = {v.cell: v.lease for v in views}
    grants.sort(key=lambda g: g.total - committed(by_cell[g.cell], now, cfg))
    return grants


def clip(grant: Grant, total: int, held: dict[str, int]) -> Grant:
    """Lower a grant so this cell's total plus what the others hold right now stays within stock."""
    others = sum(units for cell, units in held.items() if cell != grant.cell)
    allowed = max(total - others - grant.reported_sold, 0)
    if grant.remaining_qty <= allowed:
        return grant
    return Grant(grant.cell, grant.sku, allowed, grant.reported_sold, grant.epoch, grant.expires_at)
