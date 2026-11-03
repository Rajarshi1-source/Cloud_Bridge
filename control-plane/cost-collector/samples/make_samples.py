"""Writes SAMPLE FOCUS files for tests. Every amount here is made up: these files only ever load into a
scratch database (tools/dev/twin/cost.sh), never into the control plane's ledger, and no number from them
may appear anywhere as a measurement.

    python make_samples.py OUT_DIR YYYY-MM-DD
"""
import pathlib
import sys
from datetime import datetime, timedelta, timezone

import pyarrow
import pyarrow.parquet

SCHEMA = pyarrow.schema([
    ("ProviderName", pyarrow.string()), ("BillingAccountId", pyarrow.string()),
    ("ChargePeriodStart", pyarrow.timestamp("us", tz="UTC")), ("ChargePeriodEnd", pyarrow.timestamp("us", tz="UTC")),
    ("ChargeCategory", pyarrow.string()), ("ServiceCategory", pyarrow.string()), ("ServiceName", pyarrow.string()),
    ("ResourceId", pyarrow.string()), ("RegionId", pyarrow.string()),
    ("BilledCost", pyarrow.float64()), ("EffectiveCost", pyarrow.float64()), ("ListCost", pyarrow.float64()),
    ("BillingCurrency", pyarrow.string()), ("Tags", pyarrow.map_(pyarrow.string(), pyarrow.string())),
])


def row(day, category, cost, tags, service="Sample service", provider="SAMPLE"):
    return {"ProviderName": provider, "BillingAccountId": "sample-account", "ChargePeriodStart": day,
            "ChargePeriodEnd": day + timedelta(days=1), "ChargeCategory": category, "ServiceCategory": "Compute",
            "ServiceName": service, "ResourceId": "sample", "RegionId": "sample", "BilledCost": cost,
            "EffectiveCost": cost, "ListCost": cost, "BillingCurrency": "XXX", "Tags": list(tags.items())}


def write(path, rows):
    pyarrow.parquet.write_table(pyarrow.Table.from_pylist(rows, schema=SCHEMA), path)


def main() -> None:
    out, day = pathlib.Path(sys.argv[1]), datetime.fromisoformat(sys.argv[2]).replace(tzinfo=timezone.utc)
    aws, gcp = {"user:cb-cell": "cb-aws-local"}, {"cb_cell": "cb-gcp-local"}  # each cloud's own spelling
    # On the AWS cell: 10 direct to order-service, 20 shared; a credit that must not count; 5 with no cell tag.
    write(out / "aws.parquet", [
        row(day, "Usage", 10.0, {**aws, "user:cb-service": "order-service"}),
        row(day, "Usage", 20.0, aws),
        row(day, "Credit", -100.0, aws),
        row(day, "Usage", 5.0, {}, service="Untagged thing"),
    ])
    write(out / "aws-restated.parquet", [
        row(day, "Usage", 12.0, {**aws, "user:cb-service": "order-service"}),
        row(day, "Usage", 20.0, aws),
        row(day, "Credit", -100.0, aws),
        row(day, "Usage", 5.0, {}, service="Untagged thing"),
    ])
    write(out / "gcp.parquet", [row(day, "Usage", 7.0, gcp)])
    write(out / "out-of-range.parquet", [row(datetime(2001, 1, 1, tzinfo=timezone.utc), "Usage", 1.0, aws)])


if __name__ == "__main__":
    main()
