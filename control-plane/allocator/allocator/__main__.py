"""Run the allocator loop. Configuration comes from the environment:

ALLOCATOR_DATABASE_URL     control-plane Postgres
ALLOCATOR_CELLS            JSON: {"aws": "https://admin-aws.<domain>", "gcp": "https://admin-gcp.<domain>"}
ALLOCATOR_WEIGHTS_FILE     infra/live/global/30-traffic/terraform.tfvars.json (re-read every cycle)
CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET   the allocator's Cloudflare Access service token
ALLOCATOR_INTERVAL_SECONDS (300), ALLOCATOR_LEASE_TTL_SECONDS (900), ALLOCATOR_MARGIN_SECONDS (60)
ALLOCATOR_SEED_STOCK       optional "SKU-1=1000,SKU-2=200"; never overwrites an existing row
"""
import json
import logging
import os
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .adapters import HttpCells, PostgresStore
from .core import Config
from .cycle import run_cycle


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    log = logging.getLogger("allocator")
    env = os.environ
    cfg = Config(
        lease_ttl=timedelta(seconds=int(env.get("ALLOCATOR_LEASE_TTL_SECONDS", "900"))),
        regrant_margin=timedelta(seconds=int(env.get("ALLOCATOR_MARGIN_SECONDS", "60"))),
    )
    interval = int(env.get("ALLOCATOR_INTERVAL_SECONDS", "300"))
    cells = HttpCells(json.loads(env["ALLOCATOR_CELLS"]), env["CF_ACCESS_CLIENT_ID"], env["CF_ACCESS_CLIENT_SECRET"])
    store = PostgresStore(env["ALLOCATOR_DATABASE_URL"])
    if seed := env.get("ALLOCATOR_SEED_STOCK"):
        store.seed_stock({sku: int(qty) for sku, qty in (pair.split("=") for pair in seed.split(","))})
    weights_file = Path(env["ALLOCATOR_WEIGHTS_FILE"])
    while True:
        weights = json.loads(weights_file.read_text())["weights"]
        result = run_cycle(weights, cells, store, datetime.now(UTC), cfg)
        log.info(
            "cycle: %d grants %s, unreachable %s",
            len(result.applied),
            [f"{g.cell}/{g.sku}={g.total}@{g.epoch}" for g in result.applied],
            result.unreachable,
        )
        time.sleep(interval)


if __name__ == "__main__":
    main()
