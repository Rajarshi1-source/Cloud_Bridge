"""Idempotent: one transaction per source file. A re-delivered or restated export replaces only its own rows."""
from __future__ import annotations

import json

from .model import Batch

INSERT = """
INSERT INTO cost_line_items (provider_name, billing_account_id, charge_period_start, charge_period_end,
  charge_category, service_category, service_name, resource_id, region_id, billed_cost, effective_cost,
  list_cost, billing_currency, tags, source_file)
VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s)
"""


def _like_prefix(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "@%"


def write(conn, provider: str, batch: Batch) -> str:
    if not batch.rows:
        return "empty"
    with conn.transaction():
        previous = conn.execute("SELECT checksum FROM cost_ingestions WHERE source_file = %s", (batch.source_file,)).fetchone()
        if previous and previous[0] == batch.checksum:
            return "unchanged"
        conn.execute("SELECT ensure_cost_partitions()")
        versions = _like_prefix(batch.source_file.split("@", 1)[0])  # every version of the same export file
        restated = conn.execute(
            "DELETE FROM cost_ingestions WHERE source_file = %s OR source_file LIKE %s RETURNING source_file",
            (batch.source_file, versions)).fetchall()
        conn.execute("DELETE FROM cost_line_items WHERE source_file = %s OR source_file LIKE %s",
                     (batch.source_file, versions))
        with conn.cursor() as cursor:
            cursor.executemany(INSERT, [
                (r.provider_name, r.billing_account_id, r.charge_period_start, r.charge_period_end,
                 r.charge_category, r.service_category, r.service_name, r.resource_id, r.region_id,
                 r.billed_cost, r.effective_cost, r.list_cost, r.billing_currency, json.dumps(r.tags),
                 batch.source_file) for r in batch.rows])
        conn.execute(
            "INSERT INTO cost_ingestions (source_file, provider_name, period_start, row_count, checksum) VALUES (%s, %s, %s, %s, %s)",
            (batch.source_file, provider, max(r.charge_period_start for r in batch.rows).date(), len(batch.rows), batch.checksum))
    return "replaced" if restated else "inserted"
