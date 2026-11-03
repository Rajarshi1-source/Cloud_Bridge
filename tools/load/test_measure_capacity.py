"""python3 -m unittest discover -s tools/load -p 'test_*.py'"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import measure_capacity as mc  # noqa: E402


def step(rate, p95=100, errors=0.0, achieved=None):
    return {"rate": rate, "p95_ms": p95, "error_rate": errors, "achieved_rps": achieved if achieved is not None else rate}


class BestStep(unittest.TestCase):
    def test_the_highest_step_within_limits(self):
        self.assertEqual(mc.best_step([step(5), step(10), step(20, p95=400)])["rate"], 10)

    def test_errors_fail_a_step(self):
        self.assertEqual(mc.best_step([step(5), step(10, errors=0.01)])["rate"], 5)

    def test_a_rate_the_cell_could_not_keep_up_with_fails(self):
        self.assertEqual(mc.best_step([step(5), step(10, achieved=8)])["rate"], 5)

    def test_a_pass_after_a_failure_is_not_trusted(self):
        self.assertEqual(mc.best_step([step(5), step(10, p95=500), step(20)])["rate"], 5)

    def test_nothing_passed_means_no_number(self):
        self.assertIsNone(mc.best_step([step(5, p95=500)]))


class Render(unittest.TestCase):
    best = {
        "rate": 20, "p95_ms": 120.4, "error_rate": 0.001,
        "service_rps": {"api-gateway": 20.0, "order-service": 4.1, "inventory-service": 16.4},
        "pods": {"api-gateway": 2, "order-service": 1, "inventory-service": 1},
    }

    def test_per_pod_divides_by_pods(self):
        self.assertEqual(mc.per_pod_rps(self.best["service_rps"], self.best["pods"]),
                         {"api-gateway": 10.0, "order-service": 4.1, "inventory-service": 16.4})

    def test_fanout_is_relative_to_the_gateway(self):
        self.assertEqual(mc.fanout(self.best["service_rps"]), {"order-service": 0.2, "inventory-service": 0.82})

    def test_the_file_has_every_key_the_capacity_check_reads(self):
        text = mc.render_capacity(self.best, "2026-11-03T00:00:00Z", 0.2)
        for needle in ('measuredAt: "2026-11-03T00:00:00Z"', "api-gateway: 10.0", "order-service: 4.1", "inventory-service: 0.82", "gatewayRps: 20"):
            self.assertIn(needle, text)


if __name__ == "__main__":
    unittest.main()
