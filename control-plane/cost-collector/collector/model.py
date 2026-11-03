"""One row of the FOCUS ledger, whichever cloud it came from."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Iterable, Protocol


@dataclass(frozen=True)
class FocusRow:
    provider_name: str
    billing_account_id: str
    charge_period_start: datetime
    charge_period_end: datetime
    charge_category: str
    service_category: str | None
    service_name: str | None
    resource_id: str | None
    region_id: str | None
    billed_cost: Decimal
    effective_cost: Decimal
    list_cost: Decimal | None
    billing_currency: str
    tags: dict[str, str]


@dataclass(frozen=True)
class Batch:
    source_file: str  # lineage: s3://bucket/key@etag, or bq://view/day
    checksum: str
    rows: list[FocusRow]


class CostSource(Protocol):
    """One implementation per provider; callers never branch on cloud."""

    provider: str

    def batches(self, since: datetime, until: datetime) -> Iterable[Batch]: ...


TAG_KEYS = ("cb-cell", "cb-service", "cb-env", "cb-cloud")


def normalise_tags(raw) -> dict[str, str]:
    """A dict, [{key, value}] (GCP labels) or [(key, value)] (a Parquet map). Only cb-* keys, lowercase."""
    if not raw:
        return {}
    if isinstance(raw, dict):
        items = raw.items()
    else:
        items = ((t.get("key"), t.get("value")) if isinstance(t, dict) else tuple(t) for t in raw)
    out = {}
    for key, value in items:
        if not key or value is None:
            continue
        name = key.lower().replace("_", "-").removeprefix("user:")
        if name in TAG_KEYS:
            out[name] = str(value)
    return out


def _utc(moment: datetime) -> datetime:
    return moment.replace(tzinfo=timezone.utc) if moment.tzinfo is None else moment


def row_from_focus(record: dict, provider_default: str) -> FocusRow:
    """FOCUS column names, as AWS Data Exports and Google's FOCUS view both name them."""
    list_cost = record.get("ListCost")
    return FocusRow(
        provider_name=record.get("ProviderName") or provider_default,
        billing_account_id=str(record["BillingAccountId"]),
        charge_period_start=_utc(record["ChargePeriodStart"]),
        charge_period_end=_utc(record["ChargePeriodEnd"]),
        charge_category=record["ChargeCategory"],
        service_category=record.get("ServiceCategory"),
        service_name=record.get("ServiceName"),
        resource_id=record.get("ResourceId"),
        region_id=record.get("RegionId"),
        billed_cost=Decimal(str(record["BilledCost"])),
        effective_cost=Decimal(str(record["EffectiveCost"])),
        list_cost=Decimal(str(list_cost)) if list_cost is not None else None,
        billing_currency=record["BillingCurrency"],
        tags=normalise_tags(record.get("Tags")),
    )
