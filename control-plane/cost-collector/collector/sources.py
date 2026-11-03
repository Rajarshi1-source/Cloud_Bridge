"""Where FOCUS rows come from: AWS Data Exports Parquet, Google's BigQuery FOCUS view, or a local file."""
from __future__ import annotations

import hashlib
import io
import json
import pathlib
import re
from datetime import datetime, timedelta, timezone

from .model import Batch, row_from_focus


def rows_from_parquet(body: bytes, provider: str):
    import pyarrow.parquet as parquet

    return [row_from_focus(record, provider) for record in parquet.read_table(io.BytesIO(body)).to_pylist()]


class AwsFocusSource:
    """Exports are rewritten as AWS restates charges. The ETag makes each version a distinct batch, and
    the file is the unit of replacement: its rows aren't filtered by date, or a restatement would delete
    the rows outside the window and never put them back."""

    provider = "aws"

    def __init__(self, bucket: str, prefix: str, region: str = "ap-south-1", client=None):
        if client is None:
            import boto3

            client = boto3.client("s3", region_name=region)
        self.s3, self.bucket, self.prefix = client, bucket, prefix

    def batches(self, since: datetime, until: datetime):
        for page in self.s3.get_paginator("list_objects_v2").paginate(Bucket=self.bucket, Prefix=self.prefix):
            for item in page.get("Contents", []):
                if not item["Key"].endswith(".parquet") or item["LastModified"] < since:
                    continue
                body = self.s3.get_object(Bucket=self.bucket, Key=item["Key"])["Body"].read()
                rows = rows_from_parquet(body, "AWS")
                if rows:
                    etag = item["ETag"].strip('"')
                    yield Batch(f"s3://{self.bucket}/{item['Key']}@{etag}", hashlib.sha256(body).hexdigest(), rows)


VIEW_RE = re.compile(r"^[\w-]+\.[\w-]+\.[\w-]+$")
FOCUS_SQL = """
SELECT ProviderName, BillingAccountId, ChargePeriodStart, ChargePeriodEnd, ChargeCategory,
       ServiceCategory, ServiceName, ResourceId, RegionId,
       BilledCost, EffectiveCost, ListCost, BillingCurrency, Tags
FROM `{view}`
WHERE ChargePeriodStart >= @start AND ChargePeriodStart < @end
"""


class GcpFocusSource:
    """One batch per day. A window as the batch key would move with every run, so each day's rerun would
    insert its rows again beside yesterday's copy; a day is the same key on every run, and replaces itself."""

    provider = "gcp"

    def __init__(self, project: str, view: str, client=None):
        if not VIEW_RE.match(view):
            raise ValueError("the FOCUS view must be project.dataset.view, with no special characters")
        if client is None:
            from google.cloud import bigquery

            client = bigquery.Client(project=project)
        self.client, self.view = client, view

    def _query(self, start: datetime, end: datetime):
        from google.cloud import bigquery

        config = bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("start", "TIMESTAMP", start),
            bigquery.ScalarQueryParameter("end", "TIMESTAMP", end),
        ])
        return self.client.query(FOCUS_SQL.format(view=self.view), job_config=config).result()

    def batches(self, since: datetime, until: datetime):
        day = since.replace(hour=0, minute=0, second=0, microsecond=0)
        while day < until:
            end = day + timedelta(days=1)
            rows = [row_from_focus(dict(record), "Google Cloud") for record in self._query(day, end)]
            if rows:
                digest = hashlib.sha256(json.dumps([r.__dict__ for r in rows], default=str, sort_keys=True).encode()).hexdigest()
                yield Batch(f"bq://{self.view}/{day:%Y-%m-%d}", digest, rows)
            day = end


class FileFocusSource:
    """A FOCUS Parquet file on disk: sample files in tests. Never configured by the daily job."""

    def __init__(self, provider: str, path: str, key: str | None = None):
        self.provider, self.path, self.key = provider, pathlib.Path(path), key

    def batches(self, since: datetime | None = None, until: datetime | None = None):
        body = self.path.read_bytes()
        digest = hashlib.sha256(body).hexdigest()
        yield Batch(f"file://{self.key or self.path.name}@{digest[:12]}", digest, rows_from_parquet(body, self.provider))


def utc_today() -> datetime:
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
