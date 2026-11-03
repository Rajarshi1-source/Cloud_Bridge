"""Row parsing and the two sources on stand-ins for S3 and BigQuery. The writer's SQL runs against real
Postgres in tools/dev/twin/cost.sh; real exports have never been read."""
import io
import pathlib
import sys
import unittest
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from unittest import mock

HERE = pathlib.Path(__file__).resolve()
sys.path[:0] = [str(HERE.parents[1]), str(HERE.parents[1] / "samples")]
import pyarrow  # noqa: E402

from collector.model import normalise_tags, row_from_focus  # noqa: E402
from collector.pullers import opencost_allocation, request_volumes  # noqa: E402
from collector.sources import AwsFocusSource, GcpFocusSource, rows_from_parquet  # noqa: E402
from make_samples import SCHEMA, row  # noqa: E402

DAY = datetime(2026, 10, 1, tzinfo=timezone.utc)


def parquet_bytes(rows) -> bytes:
    sink = io.BytesIO()
    pyarrow.parquet.write_table(pyarrow.Table.from_pylist(rows, schema=SCHEMA), sink)
    return sink.getvalue()


class Tags(unittest.TestCase):
    def test_each_clouds_spelling_becomes_one(self):
        self.assertEqual(normalise_tags({"user:cb-cell": "x", "Other": "y"}), {"cb-cell": "x"})
        self.assertEqual(normalise_tags([{"key": "cb_cell", "value": "x"}]), {"cb-cell": "x"})
        self.assertEqual(normalise_tags([("user:cb-service", "order-service")]), {"cb-service": "order-service"})

    def test_no_tags_is_no_tags(self):
        self.assertEqual(normalise_tags(None), {})
        self.assertEqual(normalise_tags([]), {})


class Rows(unittest.TestCase):
    def test_money_stays_decimal_and_time_stays_utc(self):
        record = row(DAY.replace(tzinfo=None), "Usage", 0.1, {})
        parsed = row_from_focus(record, "AWS")
        self.assertEqual(parsed.billed_cost, Decimal("0.1"))
        self.assertEqual(parsed.charge_period_start.tzinfo, timezone.utc)

    def test_a_parquet_map_of_tags_survives(self):
        rows = rows_from_parquet(parquet_bytes([row(DAY, "Usage", 1.0, {"user:cb-cell": "cb-aws-local"})]), "AWS")
        self.assertEqual(rows[0].tags, {"cb-cell": "cb-aws-local"})


class S3Stub:
    def __init__(self, objects):
        self.objects = objects

    def get_paginator(self, _):
        return self

    def paginate(self, **_):
        return [{"Contents": [{"Key": k, "ETag": f'"{v["etag"]}"', "LastModified": v["modified"]} for k, v in self.objects.items()]}]

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key]["body"])}


class Aws(unittest.TestCase):
    def source(self, objects):
        return AwsFocusSource("b", "focus/", client=S3Stub(objects))

    def test_the_etag_names_the_version(self):
        body = parquet_bytes([row(DAY, "Usage", 1.0, {})])
        batches = list(self.source({"focus/a.parquet": {"etag": "v2", "modified": DAY, "body": body}}).batches(DAY, DAY))
        self.assertEqual(batches[0].source_file, "s3://b/focus/a.parquet@v2")

    def test_a_restated_file_keeps_its_rows_from_outside_the_window(self):
        old = DAY - timedelta(days=60)
        body = parquet_bytes([row(old, "Usage", 1.0, {}), row(DAY, "Usage", 2.0, {})])
        batches = list(self.source({"focus/a.parquet": {"etag": "v2", "modified": DAY, "body": body}}).batches(DAY, DAY + timedelta(days=1)))
        self.assertEqual(len(batches[0].rows), 2)  # the writer replaces the whole file, so it needs the whole file

    def test_a_file_untouched_since_the_window_is_not_downloaded(self):
        old = DAY - timedelta(days=60)
        self.assertEqual(list(self.source({"focus/a.parquet": {"etag": "v", "modified": old, "body": b""}}).batches(DAY, DAY)), [])

    def test_other_objects_are_ignored(self):
        self.assertEqual(list(self.source({"focus/manifest.json": {"etag": "v", "modified": DAY, "body": b"{}"}}).batches(DAY, DAY)), [])


class Gcp(unittest.TestCase):
    def source(self, rows_by_day):
        source = GcpFocusSource("p", "p.billing.focus", client=object())
        source._query = lambda start, end: rows_by_day.get(start, [])
        return source

    def test_a_view_name_can_not_carry_sql(self):
        for bad in ("p.d.v`; DROP TABLE x; --", "p.d", "p.d.v w"):
            with self.assertRaises(ValueError):
                GcpFocusSource("p", bad, client=object())

    def test_runs_on_different_days_use_the_same_key_for_the_same_day(self):
        # With the window as the key, the second run would insert the overlap again beside the first.
        rows = {DAY: [row(DAY, "Usage", 1.0, {})]}
        first = list(self.source(rows).batches(DAY - timedelta(days=2), DAY + timedelta(days=1)))
        second = list(self.source(rows).batches(DAY - timedelta(days=1), DAY + timedelta(days=2)))
        self.assertEqual([b.source_file for b in first], [b.source_file for b in second])
        self.assertEqual(first[0].source_file, "bq://p.billing.focus/2026-10-01")

    def test_an_empty_day_is_no_batch(self):
        self.assertEqual(list(self.source({}).batches(DAY, DAY + timedelta(days=2))), [])


def prom_answer(series):
    return {"data": {"result": [{"metric": {"cb_cell": c, "service": s}, "value": [0, v]} for (c, s), v in series.items()]}}


class Volumes(unittest.TestCase):
    def test_a_days_totals(self):
        answers = iter([
            prom_answer({("a", "api-gateway"): "1000.4", ("unknown-cell", "api-gateway"): "5", ("a", "postgres"): "9"}),
            prom_answer({("a", "api-gateway"): "3"}),
            prom_answer({("a", "api-gateway"): "NaN"}),
        ])
        rows = request_volumes("http://p", date(2026, 10, 1), {"a"}, query=lambda url, params: next(answers))
        self.assertEqual(rows, [(date(2026, 10, 1), "a", "api-gateway", 1000, 3, None)])

    def test_the_day_ends_at_midnight_utc(self):
        seen = mock.Mock(return_value=prom_answer({}))
        request_volumes("http://p", date(2026, 10, 1), set(), query=seen)
        self.assertEqual(seen.call_args.args[1]["time"], "2026-10-02T00:00:00+00:00")


class Allocation(unittest.TestCase):
    def test_shares_are_of_the_whole_cell(self):
        answer = {"data": [{"api-gateway": {"cpuCoreHours": 1, "ramByteHours": 1, "totalCost": 0.5},
                            "__idle__": {"cpuCoreHours": 3, "ramByteHours": 1}}]}
        rows = opencost_allocation("http://o", "a", date(2026, 10, 1), query=lambda *_: answer)
        self.assertEqual(rows, [(date(2026, 10, 1), "a", "api-gateway", 0.25, 0.5, 0.5)])

    def test_no_data_is_no_rows_never_a_guess(self):
        self.assertEqual(opencost_allocation("http://o", "a", date(2026, 10, 1), query=lambda *_: {"data": [{}]}), [])
        self.assertEqual(opencost_allocation("http://o", "a", date(2026, 10, 1), query=lambda *_: {"data": None}), [])


if __name__ == "__main__":
    unittest.main()
