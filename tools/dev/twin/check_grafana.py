#!/usr/bin/env python3
"""Every provisioned dashboard loads, and every panel's query runs without an error. No data is fine: the
panel then says "no measurement yet". A broken query, a missing table, or a stat panel whose query has no
number to show (it would claim "no measurement yet" with data in hand) is not fine.

    python3 check_grafana.py http://127.0.0.1:3000 observability/grafana/dashboards
"""
import json
import pathlib
import sys
import urllib.error
import urllib.request


def call(base: str, path: str, body=None):
    request = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def main() -> None:
    base, directory = sys.argv[1], pathlib.Path(sys.argv[2])
    failed = 0
    for path in sorted(directory.glob("*.json")):
        want = json.loads(path.read_text(encoding="utf-8"))
        status, loaded = call(base, f"/api/dashboards/uid/{want['uid']}")
        if status != 200:
            print(f"FAIL dashboard {want['title']}: HTTP {status}")
            failed += 1
            continue
        panels = loaded["dashboard"]["panels"]
        errors, empty = [], 0
        for panel in panels:
            target = dict(panel["targets"][0])
            target.update({"intervalMs": 15000, "maxDataPoints": 100})
            status, result = call(base, "/api/ds/query", {"queries": [target], "from": "now-1h", "to": "now"})
            answer = result.get("results", {}).get("A", {})
            if status != 200 or answer.get("error"):
                errors.append(f"{panel['title']}: {answer.get('error') or result.get('message') or status}")
            elif not any(frame.get("data", {}).get("values") and any(frame["data"]["values"]) for frame in answer.get("frames", [])):
                empty += 1
            elif panel["type"] == "stat" and not any(
                field.get("type") == "number" for frame in answer["frames"] for field in frame["schema"]["fields"]
            ):
                errors.append(f"{panel['title']}: a stat panel with no numeric field shows nothing")
        missing = [p["title"] for p in panels if not p.get("description") or p["fieldConfig"]["defaults"].get("noValue") != "no measurement yet"]
        if missing:
            errors.append(f"no freshness description or no-data text: {missing}")
        if errors:
            failed += 1
            print(f"FAIL dashboard {want['title']}: " + "; ".join(errors))
        else:
            print(f"ok   dashboard {want['title']}: {len(panels)} panels, every query ran, {empty} with no data yet")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
