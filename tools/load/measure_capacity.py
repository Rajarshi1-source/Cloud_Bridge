#!/usr/bin/env python3
"""Measure a cell's per-pod RPS with k6 and write it to gitops/cells/<cell>/capacity.yaml.

Raises the rate step by step and keeps the highest step that holds p95 < 300 ms and errors < 0.5%. For
that step it reads each service's own request rate from the central Prometheus, divides by its pods,
and records the fan-out it actually saw. The bottleneck service's number is its limit; the others'
are lower bounds, since they weren't pushed to their own limit.

A number measured on the twin describes the twin: this writes only to the cell it measured, and
refuses to write anything if no step passed, so the capacity check keeps refusing to evacuate there.

    python3 tools/load/measure_capacity.py --cell cb-aws-local --origin-ip 172.29.80.130 \
        --host app.example --network cb-twin_twin --prometheus http://127.0.0.1:9090 --sku SKU-LOAD
"""
import argparse
import datetime
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
K6_IMAGE = "grafana/k6:2.3.0"
P95_LIMIT_MS = 300
ERROR_LIMIT = 0.005
MAX_OUT_OF_STOCK = 0.01
SERVICES = ("api-gateway", "order-service", "inventory-service")


def step_passes(step: dict) -> bool:
    return (
        step["p95_ms"] < P95_LIMIT_MS
        and step["error_rate"] < ERROR_LIMIT
        # An arrival-rate executor that can't keep up drops iterations: the cell didn't serve that rate.
        and step["achieved_rps"] >= 0.95 * step["rate"]
    )


def best_step(steps: list[dict]) -> dict | None:
    """The last step before the first failure. A later pass after a failure isn't trusted."""
    best = None
    for step in steps:
        if not step_passes(step):
            break
        best = step
    return best


def per_pod_rps(rates: dict[str, float], pods: dict[str, int]) -> dict[str, float]:
    return {svc: round(rates[svc] / pods[svc], 1) for svc in SERVICES}


def fanout(rates: dict[str, float]) -> dict[str, float]:
    gateway = rates["api-gateway"]
    return {svc: round(rates[svc] / gateway, 2) for svc in SERVICES if svc != "api-gateway"}


def render_capacity(best: dict, measured_at: str, order_share: float) -> str:
    per_pod = per_pod_rps(best["service_rps"], best["pods"])
    fan = fanout(best["service_rps"])
    return f"""# Per-pod RPS at p95 < {P95_LIMIT_MS} ms and errors < {ERROR_LIMIT:.1%}, measured with k6 against this cell.
# Written by tools/load/measure_capacity.py; don't edit by hand. Measured on this cell's own hardware:
# it says nothing about another cell. Non-bottleneck services' numbers are lower bounds.
measuredAt: "{measured_at}"
measuredWith:
  gatewayRps: {best['rate']}
  p95Ms: {best['p95_ms']:.0f}
  errorRate: {best['error_rate']:.4f}
  orderShare: {order_share}
perPodRps:
  api-gateway: {per_pod['api-gateway']}
  order-service: {per_pod['order-service']}
  inventory-service: {per_pod['inventory-service']}
fanout:                   # downstream calls per gateway request, as measured
  order-service: {fan['order-service']}
  inventory-service: {fan['inventory-service']}
"""


def query(prometheus: str, expr: str) -> list[dict]:
    url = f"{prometheus}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.load(response)["data"]["result"]


def by_service(rows: list[dict]) -> dict[str, float]:
    return {row["metric"]["service"]: float(row["value"][1]) for row in rows}


def run_step(args, rate: int, duration: str) -> dict:
    with tempfile.TemporaryDirectory(dir=pathlib.Path.home()) as out:
        pathlib.Path(out).chmod(0o777)
        subprocess.run(
            ["docker", "run", "--rm", "--network", args.network, "-u", "root",
             "-v", f"{ROOT / 'tools/load'}:/scripts:ro", "-v", f"{out}:/out",
             "-e", f"CB_HOST={args.host}", "-e", f"CB_ORIGIN_IP={args.origin_ip}", "-e", f"CB_SKU={args.sku}",
             "-e", f"CB_RATE={rate}", "-e", f"CB_DURATION={duration}", "-e", f"CB_ORDER_SHARE={args.order_share}",
             K6_IMAGE, "run", "--quiet", "--log-output", "none", "/scripts/per-pod-rps.js"],
            check=True, stdout=subprocess.DEVNULL,
        )
        metrics = json.loads((pathlib.Path(out) / "summary.json").read_text())["metrics"]
    count = lambda name: metrics.get(name, {}).get("values", {}).get("count", 0)
    return {
        "rate": rate,
        "p95_ms": metrics["http_req_duration"]["values"]["p(95)"],
        "error_rate": metrics["http_req_failed"]["values"]["rate"],
        "achieved_rps": metrics["http_reqs"]["values"]["rate"],
        "requests": metrics["http_reqs"]["values"]["count"],
        "out_of_stock": count("cb_out_of_stock"),
        "no_answer": count("cb_no_answer"),
        "unavailable": count("cb_503"),
        "other_error": count("cb_other_error"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cell", required=True)
    parser.add_argument("--origin-ip", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--network", required=True)
    parser.add_argument("--prometheus", required=True)
    parser.add_argument("--sku", required=True)
    parser.add_argument("--rates", default="5,10,20,40,80,160")
    parser.add_argument("--step-seconds", type=int, default=120)
    parser.add_argument("--order-share", type=float, default=0.2)
    args = parser.parse_args()

    print("warm-up: JIT compilation and connection pools, not measured")
    run_step(args, 5, "60s")
    steps = []
    selector = f'cb_cell="{args.cell}",uri!~"/actuator.*|/healthz.*"'
    for rate in (int(r) for r in args.rates.split(",")):
        step = run_step(args, rate, f"{args.step_seconds}s")
        time.sleep(20)  # one scrape plus one remote-write flush
        step["service_rps"] = by_service(query(args.prometheus, f"sum by (service) (rate(http_server_requests_seconds_count{{{selector}}}[1m] offset 20s))"))
        step["pods"] = {k: int(v) for k, v in by_service(query(args.prometheus, f'count by (service) (up{{job="apps",cb_cell="{args.cell}"}} == 1)')).items()}
        steps.append(step)
        verdict = "pass" if step_passes(step) else "FAIL"
        print(f"{rate:>4} rps: achieved {step['achieved_rps']:.1f}, p95 {step['p95_ms']:.0f} ms, errors {step['error_rate']:.2%}, "
              f"out of stock {step['out_of_stock']}, no answer {step['no_answer']}, 503 {step['unavailable']}, other {step['other_error']}, "
              f"{ {k: round(v, 1) for k, v in step['service_rps'].items()} } -> {verdict}", flush=True)
        if verdict == "FAIL":
            break

    best = best_step(steps)
    if best is None or any(s not in best["service_rps"] or s not in best["pods"] for s in SERVICES):
        sys.exit("no step passed with every service measured: capacity.yaml is unchanged")
    if best["out_of_stock"] > MAX_OUT_OF_STOCK * best["requests"]:
        sys.exit(f"{best['out_of_stock']} of {best['requests']} requests ran out of stock, which skips the order path: capacity.yaml is unchanged")
    measured_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path = ROOT / "gitops/cells" / args.cell / "capacity.yaml"
    path.write_text(render_capacity(best, measured_at, args.order_share), encoding="utf-8", newline="\n")
    print(f"wrote {path.relative_to(ROOT)}: {per_pod_rps(best['service_rps'], best['pods'])}, fan-out {fanout(best['service_rps'])}")


if __name__ == "__main__":
    main()
