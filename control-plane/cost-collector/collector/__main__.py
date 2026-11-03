"""The daily job, and the pieces it runs. Anything not configured says so, and writes nothing:

    python -m collector cells --cells parity/cells.yaml      # the cells the ledger may name
    python -m collector ledger                               # FOCUS exports, if their sources are set
    python -m collector volumes --days 3                     # request counts from Prometheus
    python -m collector allocation --days 3                  # service shares from each cell's OpenCost
    python -m collector file --provider aws --path x.parquet # one sample file, for tests
"""
import argparse
import json
import os
from datetime import timedelta

import psycopg
import yaml

from .pullers import opencost_allocation, request_volumes
from .sources import AwsFocusSource, FileFocusSource, GcpFocusSource, utc_today
from .writer import write


def sources():
    bucket, view = os.environ.get("CB_AWS_FOCUS_BUCKET"), os.environ.get("CB_GCP_FOCUS_VIEW")
    if bucket:
        yield AwsFocusSource(bucket, os.environ.get("CB_AWS_FOCUS_PREFIX", "focus/"))
    else:
        print("ledger: AWS export not configured (CB_AWS_FOCUS_BUCKET), not measured")
    if view:
        yield GcpFocusSource(os.environ["GCP_PROJECT_ID"], view)
    else:
        print("ledger: GCP export not configured (CB_GCP_FOCUS_VIEW), not measured")


def ledger(conn) -> None:
    until = utc_today()
    since = until - timedelta(days=int(os.environ.get("COST_LOOKBACK_DAYS", "35")))  # catches restatements
    for source in sources():
        for batch in source.batches(since, until):
            print(source.provider, batch.source_file, write(conn, source.provider, batch), len(batch.rows))


def sync_cells(conn, path: str) -> None:
    environments = yaml.safe_load(open(path, encoding="utf-8"))
    for env, content in environments.items():
        for cell, config in content["cells"].items():
            conn.execute("""INSERT INTO cells (id, cloud, profile, env, region, stack_path, shape)
                            VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb)
                            ON CONFLICT (id) DO UPDATE SET cloud = EXCLUDED.cloud, profile = EXCLUDED.profile, env = EXCLUDED.env,
                              region = EXCLUDED.region, stack_path = EXCLUDED.stack_path, shape = EXCLUDED.shape""",
                         (cell, config["cloud"], config["profile"], env, config["region"], config["stack"], json.dumps(config["shape"])))
    print(f"cells: {sum(len(c['cells']) for c in environments.values())}")


def known_cells(conn) -> set[str]:
    return {row[0] for row in conn.execute("SELECT id FROM cells")}


def volumes(conn, days: int) -> None:
    prometheus = os.environ.get("CB_PROM_URL")
    if not prometheus:
        print("volumes: CB_PROM_URL not configured, not measured")
        return
    cells = known_cells(conn)
    # Today is left out: a day's requests are complete only once the day is over.
    for back in range(1, days + 1):
        day = (utc_today() - timedelta(days=back)).date()
        rows = request_volumes(prometheus, day, cells)
        with conn.cursor() as cursor:
            cursor.executemany("""INSERT INTO request_volume_daily (day, cell_id, service, requests, errors, p95_ms)
                                  VALUES (%s, %s, %s, %s, %s, %s)
                                  ON CONFLICT (day, cell_id, service) DO UPDATE SET requests = EXCLUDED.requests,
                                    errors = EXCLUDED.errors, p95_ms = EXCLUDED.p95_ms""", rows)
        print(f"volumes: {day}: {len(rows)} rows")


def allocation(conn, days: int) -> None:
    urls = json.loads(os.environ.get("CB_OPENCOST_URLS", "{}"))  # {"cb-aws-prod": "https://..."}
    if not urls:
        print("allocation: no cell runs OpenCost (CB_OPENCOST_URLS), not measured")
        return
    for cell, url in urls.items():
        for back in range(1, days + 1):
            rows = opencost_allocation(url, cell, (utc_today() - timedelta(days=back)).date())
            with conn.cursor() as cursor:
                cursor.executemany("""INSERT INTO allocation_daily (day, cell_id, service, cpu_share, mem_share, opencost_estimate)
                                      VALUES (%s, %s, %s, %s, %s, %s)
                                      ON CONFLICT (day, cell_id, service) DO UPDATE SET cpu_share = EXCLUDED.cpu_share,
                                        mem_share = EXCLUDED.mem_share, opencost_estimate = EXCLUDED.opencost_estimate""", rows)


def main() -> None:
    parser = argparse.ArgumentParser(prog="collector")
    parser.add_argument("job", choices=["daily", "cells", "ledger", "volumes", "allocation", "file"])
    parser.add_argument("--cells", default=os.environ.get("CB_CELLS_FILE", "parity/cells.yaml"))
    parser.add_argument("--days", type=int, default=3)  # a rerun repairs what a missed day left
    parser.add_argument("--provider")
    parser.add_argument("--path")
    parser.add_argument("--key", help="file: a stable name, so a corrected file replaces the earlier one")
    args = parser.parse_args()
    with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
        if args.job in ("cells", "daily"):
            sync_cells(conn, args.cells)
        if args.job in ("ledger", "daily"):
            ledger(conn)
        if args.job in ("volumes", "daily"):
            volumes(conn, args.days)
        if args.job in ("allocation", "daily"):
            allocation(conn, args.days)
        if args.job == "file":
            source = FileFocusSource(args.provider, args.path, args.key)
            for batch in source.batches():
                print(batch.source_file, write(conn, args.provider, batch), len(batch.rows))


if __name__ == "__main__":
    main()
