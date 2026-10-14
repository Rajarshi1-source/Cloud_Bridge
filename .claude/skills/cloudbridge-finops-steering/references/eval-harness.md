# Steering Recommender — Backtest Eval Harness

The recommender makes a decision that moves real users, so it gets an offline replay before any PR it opens can be trusted. The harness answers two questions for every change to `control-plane/steering/**`:

1. **Safety:** replaying the policy over history, would any week have breached the latency SLO or capacity headroom? (Gate: **zero** violations.)
2. **Value:** how much variable cost does the policy save vs static 70/30, and did this change make it worse than the last merged model? (Gate: no more than 20% regression.)

Until you have 90 days of real ledger data, the harness runs on **synthetic history** with known ground truth (the generator below). As real data accrues, `history.real.csv` is exported from Q5 (`schema-and-queries.md`) and the gate runs on both — synthetic for regression coverage, real for honesty.

## Layout

```
evals/steering/
  generate.py            synthetic 90-day history with known ground-truth cost and latency curves
  backtest.py            weekly replay: fit on trailing 28 days → recommend → simulate next 7 days
  scenarios.yaml         scenario parameters (who's cheaper, capacity limits, latency knees)
  baseline.json          last merged model's results (updated by the bot on merge to main)
```

## scenarios.yaml

```yaml
- name: gcp-cheaper-marginal
  days: 90
  noise: 0.01
  total_req_day: 2_000_000
  peak_rps: 60
  cells:
    aws: { fixed_inr_day: 900, marginal_inr_per_1k: 0.30, capacity_rps: 120, p95_base_ms: 120, p95_knee_share: 0.85 }
    gcp: { fixed_inr_day: 600, marginal_inr_per_1k: 0.22, capacity_rps: 70,  p95_base_ms: 130, p95_knee_share: 0.70 }
  expect: { direction: towards_gcp }

- name: aws-cheaper-but-gcp-capacity-tight
  days: 90
  noise: 0.01
  total_req_day: 2_000_000
  peak_rps: 60
  cells:
    aws: { fixed_inr_day: 900, marginal_inr_per_1k: 0.18, capacity_rps: 120, p95_base_ms: 120, p95_knee_share: 0.9 }
    gcp: { fixed_inr_day: 600, marginal_inr_per_1k: 0.25, capacity_rps: 30,  p95_base_ms: 130, p95_knee_share: 0.6 }
  expect: { direction: towards_aws }

- name: equal-costs-noise-only            # hysteresis must hold: no change proposed
  days: 90
  total_req_day: 2_000_000
  peak_rps: 60
  noise: 0.08
  cells:
    aws: { fixed_inr_day: 800, marginal_inr_per_1k: 0.24, capacity_rps: 120, p95_base_ms: 120, p95_knee_share: 0.9 }
    gcp: { fixed_inr_day: 800, marginal_inr_per_1k: 0.24, capacity_rps: 120, p95_base_ms: 120, p95_knee_share: 0.9 }
  expect: { direction: none }

- name: starts-unsafe-aws-overloaded     # aws is cheaper but 70% already exceeds its headroom → must move away
  days: 90
  noise: 0.01
  total_req_day: 2_000_000
  peak_rps: 60
  cells:
    aws: { fixed_inr_day: 900, marginal_inr_per_1k: 0.18, capacity_rps: 45,  p95_base_ms: 120, p95_knee_share: 0.95 }
    gcp: { fixed_inr_day: 600, marginal_inr_per_1k: 0.25, capacity_rps: 120, p95_base_ms: 130, p95_knee_share: 0.95 }
  expect: { direction: towards_gcp }

- name: small-gap-near-noise-no-oscillation   # real but small gap + seasonality: a naive policy goes 70→50→70
  days: 120
  noise: 0.05
  total_req_day: 2_000_000
  peak_rps: 60
  cells:
    aws: { fixed_inr_day: 900, marginal_inr_per_1k: 0.24, capacity_rps: 120, p95_base_ms: 120, p95_knee_share: 0.9 }
    gcp: { fixed_inr_day: 600, marginal_inr_per_1k: 0.22, capacity_rps: 120, p95_base_ms: 125, p95_knee_share: 0.9 }
  expect: { max_reversals: 0 }

- name: latency-knee-blocks-savings       # cheaper cell degrades past 50% share
  days: 90
  total_req_day: 2_000_000
  peak_rps: 60
  cells:
    aws: { fixed_inr_day: 900, marginal_inr_per_1k: 0.30, capacity_rps: 120, p95_base_ms: 120, p95_knee_share: 0.9 }
    gcp: { fixed_inr_day: 600, marginal_inr_per_1k: 0.15, capacity_rps: 33,  p95_base_ms: 150, p95_knee_share: 0.5 }
    # capacity_rps is the k6-measured rate at p95 < 300 ms — load testing is what reveals the knee in advance
  expect: { direction: towards_gcp, max_gcp_share: 0.6 }
```

## generate.py

```python
# evals/steering/generate.py
"""Ground truth: daily_cost = F + v × requests (× noise); p95(share) flat until a knee, then steep."""
import numpy as np

def true_p95(base_ms: float, knee: float, share: float) -> float:
    return base_ms if share <= knee else base_ms + 900 * (share - knee) ** 1.5 * 10

def daily_total(base: float, day: int) -> float:
    """Weekly seasonality (±25%) — real traffic varies, and that variation is what identifies marginal cost."""
    return base * (1 + 0.25 * np.sin(2 * np.pi * day / 7))

def simulate_day(rng, cell: dict, share: float, total_req: float, noise: float) -> dict:
    req = total_req * share
    cost = (cell["fixed_inr_day"] + cell["marginal_inr_per_1k"] / 1000 * req) * (1 + rng.normal(0, noise))
    p95 = true_p95(cell["p95_base_ms"], cell["p95_knee_share"], share) * (1 + rng.normal(0, noise / 2))
    return {"requests": req, "cost": max(cost, 0.0), "p95": p95}

def history(scn: dict, shares_aws: list[float], seed: int = 7) -> dict[str, list[dict]]:
    """Generate history under a given sequence of aws shares (exploration matters: a constant 70/30
    history gives the latency fit only one point per cell — see the note in backtest.py)."""
    rng = np.random.default_rng(seed)
    noise = scn.get("noise", 0.04)
    out = {"aws": [], "gcp": []}
    for s in shares_aws:
        out["aws"].append({**simulate_day(rng, scn["cells"]["aws"], s, scn["total_req_day"], noise), "share": s})
        out["gcp"].append({**simulate_day(rng, scn["cells"]["gcp"], 1 - s, scn["total_req_day"], noise), "share": 1 - s})
    return out
```

## backtest.py

```python
# evals/steering/backtest.py
import json, pathlib, sys
import numpy as np, yaml

HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parents[1] / "control-plane"))
sys.path.insert(0, str(HERE))
from steering.recommender import CellModel, fit_cost, fit_p95, recommend   # noqa: E402
from generate import daily_total, simulate_day, true_p95                    # noqa: E402

P95_SLO = 300.0
REGRESSION_LIMIT = 0.20
WARMUP_DAYS = 28

def run(scn: dict, seed: int = 11) -> dict:
    rng = np.random.default_rng(seed)
    noise = scn.get("noise", 0.04)
    cells, R, peak = scn["cells"], scn["total_req_day"], scn["peak_rps"]
    w = 0.70
    # Warm-up history: small deliberate wobble (±5 points) so the latency fit has more than one point.
    hist = {"aws": [], "gcp": []}
    for d in range(WARMUP_DAYS):
        s = 0.70 + 0.05 * np.sin(d / 3)
        for name, share in (("aws", s), ("gcp", 1 - s)):
            hist[name].append({**simulate_day(rng, cells[name], share, daily_total(R, d), noise), "share": share})

    cost_policy = cost_static = 0.0
    violations, shares = 0, []
    last_dir, reversals = 0, 0
    for week in range((scn["days"] - WARMUP_DAYS) // 7):
        models = {}
        for name in ("aws", "gcp"):
            h = hist[name][-28:]
            F, v, se = fit_cost(np.array([x["requests"] for x in h]), np.array([x["cost"] for x in h]))
            shares_h = np.array([x["share"] for x in h])
            p95f = fit_p95(shares_h, np.array([x["p95"] for x in h]))
            models[name] = CellModel(name, F, v, cells[name]["capacity_rps"], p95f,
                                     marginal_se=se, observed_max_share=float(shares_h.max()),
                                     distinct_shares=len(np.unique(np.round(shares_h, 2))))
        rec = recommend(models["aws"], models["gcp"], R, peak, current_aws=w, last_direction=last_dir)
        if abs(rec.w_aws - w) > 1e-9:
            reversals += int(last_dir != 0 and (rec.w_aws > w) != (last_dir > 0))
            last_dir = 1 if rec.w_aws > w else -1
        w = rec.w_aws
        shares.append(w)
        for dd in range(7):
            day_no = WARMUP_DAYS + week * 7 + dd
            R_day = daily_total(R, day_no)
            for name, share in (("aws", w), ("gcp", 1 - w)):
                day = simulate_day(rng, cells[name], share, R_day, noise)
                hist[name].append({**day, "share": share})
                cost_policy += cells[name]["marginal_inr_per_1k"] / 1000 * day["requests"]
                # ground-truth checks, not the model's own predictions
                if true_p95(cells[name]["p95_base_ms"], cells[name]["p95_knee_share"], share) > P95_SLO:
                    violations += 1
                if share * peak > cells[name]["capacity_rps"]:
                    violations += 1
            cost_static += R_day * (0.7 * cells["aws"]["marginal_inr_per_1k"] + 0.3 * cells["gcp"]["marginal_inr_per_1k"]) / 1000
    saving_pct = 100 * (1 - cost_policy / cost_static) if cost_static else 0.0
    return {"weeks": len(shares), "final_aws_share": shares[-1] if shares else w, "slo_violations": violations,
            "direction_reversals": reversals,
            "saving_vs_static_pct": round(saving_pct, 2), "shares": [round(s, 2) for s in shares]}

def check_expectation(scn: dict, res: dict) -> str | None:
    exp, final = scn.get("expect", {}), res["final_aws_share"]
    d = exp.get("direction")
    if d == "towards_gcp" and final >= 0.70:
        return f"expected movement towards GCP, final aws share {final}"
    if d == "towards_aws" and final <= 0.70:
        return f"expected movement towards AWS, final aws share {final}"
    if d == "none" and abs(final - 0.70) > 1e-9:
        return f"expected no change under noise, final aws share {final}"
    if "max_gcp_share" in exp and 1 - final > exp["max_gcp_share"] + 1e-9:
        return f"gcp share {1 - final:.2f} exceeds {exp['max_gcp_share']}"
    return None

def main() -> int:
    scenarios = yaml.safe_load((HERE / "scenarios.yaml").read_text())
    baseline_path = HERE / "baseline.json"
    baseline = json.loads(baseline_path.read_text()) if baseline_path.exists() else {}
    results, failed = {}, False
    for scn in scenarios:
        res = run(scn)
        results[scn["name"]] = res
        problems = []
        if res["slo_violations"]:
            problems.append(f"{res['slo_violations']} SLO/capacity violations in replay")
        if (msg := check_expectation(scn, res)):
            problems.append(msg)
        if res["direction_reversals"] > scn.get("expect", {}).get("max_reversals", 0):
            problems.append(f"{res['direction_reversals']} direction reversals — the policy is oscillating")
        prev = baseline.get(scn["name"], {}).get("saving_vs_static_pct")
        if prev and prev > 0 and res["saving_vs_static_pct"] < prev * (1 - REGRESSION_LIMIT):
            problems.append(f"saving regressed {prev}% → {res['saving_vs_static_pct']}%")
        status = "FAIL" if problems else "ok"
        failed |= bool(problems)
        print(f"{status:4} {scn['name']:<40} saving={res['saving_vs_static_pct']:>6}% final_aws={res['final_aws_share']} {'; '.join(problems)}")
    pathlib.Path("steering-backtest.json").write_text(json.dumps(results, indent=2))
    print("GATE FAIL" if failed else "GATE PASS")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
```

### Why the warm-up wobble exists
If history is a constant 70/30 split, each cell's latency curve has exactly one observed share and the piecewise fit can't extrapolate — the recommender would either refuse to move or extrapolate blindly. The ±5-point wobble in the synthetic warm-up mirrors what you do in production: the weekly 20-point step limit plus drills give the model observations at new shares. In the real system, the first recommender runs are deliberately conservative (max step 0.10) until the latency fit covers at least three distinct shares per cell.

### What "violation" means
Violations are checked against the **ground-truth** curves, not the model's predictions — otherwise a model that predicts badly would also grade itself as safe. That is the same separation as grading on a held-out set.

## CI

```yaml
# .github/workflows/evals.yml (steering job)
  steering:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-python@<sha>
        with:
          python-version: "3.14"
      - run: pip install numpy pyyaml
      - run: python3 evals/steering/backtest.py
      - uses: actions/upload-artifact@<sha>
        with:
          name: steering-backtest
          path: steering-backtest.json
```
On merge to `main`, a bot commits `steering-backtest.json` as `evals/steering/baseline.json` so the next PR is compared against the model that actually shipped.
