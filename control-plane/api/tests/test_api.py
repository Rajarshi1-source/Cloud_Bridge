"""The capacity arithmetic and the routes' refusals, with no database or Prometheus. The SQL runs against
real Postgres in tools/dev/twin/cost.sh and twin.sh parity."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
os.environ["CB_CP_TOKEN"] = "test-token"
os.environ.setdefault("DATABASE_URL", "postgresql://unused")

from fastapi.testclient import TestClient  # noqa: E402

from cpapi import capacity as cap  # noqa: E402
from cpapi import main  # noqa: E402

HEADERS = {"Authorization": "Bearer test-token"}
MEASURED = {"perPodRps": {"api-gateway": 40, "order-service": 8, "inventory-service": 48},
            "fanout": {"order-service": 0.2, "inventory-service": 1.2}, "measuredAt": "2026-11-03T00:00:00Z"}
MAXIMA = {"api-gateway": 6, "order-service": 4, "inventory-service": 2}


class Capacity(unittest.TestCase):
    def rows(self, current=None):
        return cap.per_service(MEASURED, MAXIMA, current or {})

    def test_it_divides_by_fanout_and_takes_the_lowest(self):
        rows = {r["service"]: r["capacity_rps"] for r in self.rows()}
        self.assertEqual(rows, {"api-gateway": 240, "order-service": 160, "inventory-service": 80})
        result = cap.summary("c", MEASURED, self.rows(), 40.0)
        self.assertEqual(result["capacity_rps"], 80)
        self.assertEqual(result["capacity_ratio"], 2)

    def test_unknown_current_replicas_is_no_ratio_rather_than_zero(self):
        self.assertIsNone(cap.summary("c", MEASURED, self.rows(), 40.0)["capacity_ratio_at_current_replicas"])
        current = {"api-gateway": 1, "order-service": 1, "inventory-service": 1}
        self.assertEqual(cap.summary("c", MEASURED, self.rows(current), 40.0)["capacity_ratio_at_current_replicas"], 1)

    def test_an_unmeasured_service_is_refused(self):
        for broken in ({**MEASURED, "perPodRps": {**MEASURED["perPodRps"], "order-service": 0}},
                       {**MEASURED, "fanout": {"inventory-service": 1.2}},
                       {}):
            with self.assertRaises(cap.NotMeasured):
                cap.per_service(broken, MAXIMA, {})

    def test_no_traffic_history_is_refused(self):
        for peak in (None, 0.0):
            with self.assertRaises(cap.NotMeasured):
                cap.summary("c", MEASURED, self.rows(), peak)

    def test_the_plan_rounds_up_and_reports_what_hpa_max_cannot_reach(self):
        summary = cap.summary("c", MEASURED, self.rows(), 40.0)
        plan = {s["service"]: s for s in cap.evacuation_plan(summary, 1.2)["services"]}
        self.assertEqual(plan["api-gateway"]["min_replicas"], 2)        # 48 / 40 rounds up
        self.assertEqual(plan["inventory-service"]["min_replicas"], 2)  # 48 x 1.2 / 48 = 1.2
        self.assertEqual(plan["order-service"]["min_replicas"], 2)      # 48 x 0.2 / 8 = 1.2
        tight = cap.summary("c", MEASURED, self.rows(), 400.0)
        plan = {s["service"]: s for s in cap.evacuation_plan(tight, 1.2)["services"]}
        self.assertEqual((plan["inventory-service"]["min_replicas"], plan["inventory-service"]["shortfall_replicas"]), (2, 10))


class CellFiles(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = pathlib.Path(tmp.name)
        (self.repo / "gitops" / "cells" / "cb-aws-x").mkdir(parents=True)
        (self.repo / "gitops" / "charts" / "order-service").mkdir(parents=True)
        (self.repo / "gitops" / "cells" / "cb-aws-x" / "capacity.yaml").write_text("measuredAt: then\n")
        (self.repo / "gitops" / "cells" / "cb-aws-x" / "values.yaml").write_text("replicas: {max: 9}\n")
        (self.repo / "gitops" / "charts" / "order-service" / "values.yaml").write_text("replicas: {max: 4}\n")
        (self.repo / "gitops" / "capacity.yaml").write_text("measuredAt: outside\n")
        (self.repo / "gitops" / "values.yaml").write_text("replicas: {max: 99}\n")

    def test_a_cell_reads_its_own_files(self):
        self.assertEqual(cap.measured(self.repo, "cb-aws-x"), {"measuredAt": "then"})
        self.assertEqual(cap.hpa_max(self.repo, "cb-aws-x", "order-service"), 9)

    def test_a_name_cannot_leave_the_cells_directory(self):
        for name in ("..", "../", "cb-aws-x/../..", str(self.repo / "gitops")):
            with self.subTest(name), self.assertRaises(cap.NotMeasured):
                cap.measured(self.repo, name)
            with self.subTest(name), self.assertRaises(cap.NotMeasured):
                cap.hpa_max(self.repo, name, "order-service")


class Conn:
    """Answers env_of and nothing else."""

    def __init__(self, env="local"):
        self.env = env

    def execute(self, sql, params=None):
        return mock.Mock(fetchone=lambda: (self.env,) if self.env else None, fetchall=lambda: [])


class Routes(unittest.TestCase):
    def setUp(self):
        main.app.dependency_overrides[main.db] = lambda: Conn()
        self.addCleanup(main.app.dependency_overrides.clear)
        self.client = TestClient(main.app)

    def test_a_cell_name_with_a_trailing_newline_is_unknown(self):
        self.assertEqual(self.client.get("/capacity/cb-aws-x%0A", headers=HEADERS).status_code, 404)

    def test_every_route_but_health_needs_the_token(self):
        open_routes = {"/healthz", "/metrics"}
        for route in main.app.routes:
            path = getattr(route, "path", "")
            if path in open_routes or path.startswith(("/docs", "/redoc", "/openapi")):
                continue
            for method in route.methods - {"HEAD", "OPTIONS"}:
                url = path.replace("{cell}", "cb-aws-local").replace("{drill_id}", "00000000-0000-0000-0000-000000000000")
                self.assertEqual(self.client.request(method, url, json={}).status_code, 401, f"{method} {path}")
                wrong = self.client.request(method, url, json={}, headers={"Authorization": "Bearer nope"})
                self.assertEqual(wrong.status_code, 401, f"{method} {path}")

    def test_health_needs_no_token(self):
        self.assertEqual(self.client.get("/healthz").status_code, 200)

    def test_it_will_not_start_without_a_token(self):
        env = {k: v for k, v in os.environ.items() if k != "CB_CP_TOKEN"}
        done = subprocess.run([sys.executable, "-c", "import cpapi.main"], cwd=pathlib.Path(__file__).resolve().parents[1],
                              env=env, capture_output=True, text=True)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("CB_CP_TOKEN", done.stderr)

    def test_a_cell_name_can_not_reach_a_path_or_a_selector(self):
        for bad in ("..%2f..%2fetc", 'cb-aws-x"}', "nope"):
            self.assertEqual(self.client.get(f"/capacity/{bad}", headers=HEADERS).status_code, 404, bad)

    def test_a_snapshot_cannot_claim_a_pass_below_one(self):
        body = {"env": "local", "score": 0.9, "passed": True, "trigger": "manual",
                "findings": [{"check_id": "x", "weight": 1, "values": {}, "status": "match"}]}
        self.assertEqual(self.client.post("/parity/snapshots", json=body, headers=HEADERS).status_code, 422)

    def test_a_snapshot_needs_known_statuses_and_some_findings(self):
        body = {"env": "local", "score": 1, "passed": True, "trigger": "manual", "findings": []}
        self.assertEqual(self.client.post("/parity/snapshots", json=body, headers=HEADERS).status_code, 422)
        body["findings"] = [{"check_id": "x", "weight": 1, "values": {}, "status": "fine"}]
        self.assertEqual(self.client.post("/parity/snapshots", json=body, headers=HEADERS).status_code, 422)

    def test_capacity_refuses_when_prometheus_is_down(self):
        with mock.patch.object(main, "prom", side_effect=main.PrometheusDown("no route")), \
                mock.patch.object(cap, "measured", return_value=MEASURED):
            self.assertEqual(self.client.get("/capacity/cb-aws-local", headers=HEADERS).status_code, 503)

    def test_capacity_refuses_with_no_measurement(self):
        with mock.patch.object(cap, "measured", side_effect=cap.NotMeasured("never measured")):
            answer = self.client.get("/capacity/cb-aws-local", headers=HEADERS)
        self.assertEqual(answer.status_code, 409)
        self.assertIn("never measured", answer.text)


if __name__ == "__main__":
    unittest.main()
