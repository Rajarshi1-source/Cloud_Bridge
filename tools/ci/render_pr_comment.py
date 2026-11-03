#!/usr/bin/env python3
"""The one sticky comment on an infrastructure PR: both plans, cost delta and policy result.

    python3 tools/ci/render_pr_comment.py <artifacts-dir> > comment.md

Reads report-*/{report,conftest,infracost}.json, affected/affected.json and static/static.txt. Exits 1
when a policy failed, so the job fails after the comment is posted. Anything not measured says so:
a stack that wasn't planned never shows a zero cost or a clean policy result.
"""
import json
import pathlib
import sys

NOT_MEASURED = "not measured"


def read_json(path: pathlib.Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def policy_cell(conftest) -> tuple[str, int]:
    """conftest --output json: a list with one entry per input file, or nothing if it didn't run."""
    if conftest is None:
        return NOT_MEASURED, 0
    failures = sum(len(entry.get("failures") or []) for entry in conftest)
    return ("✅ pass", 0) if failures == 0 else (f"⛔ {failures} failed", failures)


def cost_cell(infracost) -> str:
    if not infracost or infracost.get("diffTotalMonthlyCost") is None:
        return NOT_MEASURED
    return f"{float(infracost['diffTotalMonthlyCost']):+.2f} {infracost.get('currency', 'USD')}/mo"


def plan_cell(report: dict) -> str:
    if report.get("status") != "planned":
        return f"not planned: {report.get('reason', 'unknown')}"
    c = report["counts"]
    return f"+{c['add']} ~{c['change']} -{c['destroy']}"


def one_sided(reports: list[dict]) -> bool:
    """The cell module holds both clouds' code, so only the plans show which cloud actually changes."""
    changing = {r["cloud"] for r in reports if r.get("status") == "planned" and any(r["counts"].values())}
    return len(changing & {"aws", "gcp"}) == 1


def render(root: pathlib.Path) -> tuple[str, int]:
    rows, details, reports, failed = [], [], [], 0
    for directory in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("report-")):
        report = read_json(directory / "report.json")
        if report is None:
            continue
        reports.append(report)
        conftest = read_json(directory / "conftest.json")
        policy, failures = policy_cell(conftest)
        failed += failures
        rows.append(f"| `{report['stack']}` | {plan_cell(report)} | {policy} | {cost_cell(read_json(directory / 'infracost.json'))} |")
        for entry in conftest or []:
            details.extend(f"- `{report['stack']}`: {f['msg']}" for f in entry.get("failures") or [])
        if report.get("plan_sha256"):
            details.append(f"- `{report['stack']}` plan sha256 `{report['plan_sha256']}`")

    lines = ["## CloudBridge infrastructure plan", ""]
    affected = read_json(root / "affected" / "affected.json") or {}
    if rows:
        lines += ["| Stack | Plan (add, change, destroy) | Policy | Cost delta |", "|---|---|---|---|", *rows, ""]
    else:
        lines += ["No stack that CI plans is affected by this change.", ""]
    if one_sided(reports):
        lines += ["⚠️ **One-sided change:** only one cloud's plan changes anything. That is a parity divergence unless an exception explains it.", ""]
    if affected.get("not_planned"):
        lines += ["Affected, not planned here (offline tests cover them): " + ", ".join(f"`{p}`" for p in affected["not_planned"]), ""]
    static = root / "static" / "static.txt"
    if static.exists():
        lines += [f"**Static checks (fmt, tflint, Trivy, Conftest unit tests):** {static.read_text(encoding='utf-8').strip()}", ""]
    if details:
        lines += ["<details><summary>Details</summary>", "", *details, "", "</details>", ""]
    return "\n".join(lines), failed


def main() -> None:
    comment, failed = render(pathlib.Path(sys.argv[1]))
    print(comment)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
