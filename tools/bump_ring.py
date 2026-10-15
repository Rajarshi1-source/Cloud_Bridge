#!/usr/bin/env python3
"""Update a release ring file with image digests.

New build (ci-app.yml, after main publishes):
    DOCKERHUB_USER=me bump_ring.py --ring ring-canary --digests digests.env
Promotion (ring-promote.yml, after the canary soak):
    bump_ring.py --ring ring-main --from-ring ring-canary

digests.env holds one `service=sha256:<64 hex>` per line. The file's leading comment block is kept.
"""
import argparse
import datetime
import os
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASES = ROOT / "gitops" / "releases"
SERVICES = ("api-gateway", "order-service", "inventory-service")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REF = re.compile(r"^[a-z0-9][a-z0-9_.-]*/cb-[a-z-]+@sha256:[0-9a-f]{64}$")


def read_ring(name: str) -> tuple[str, dict]:
    text = (RELEASES / f"{name}.yaml").read_text(encoding="utf-8")
    header = "".join(line for line in text.splitlines(keepends=True) if line.startswith("#"))
    return header, yaml.safe_load(text) or {}


def parse_digests(path: str) -> dict[str, str]:
    found = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").split():
        svc, _, digest = line.partition("=")
        if svc not in SERVICES:
            sys.exit(f"unknown service {svc!r}; expected one of {SERVICES}")
        if not DIGEST.match(digest):
            sys.exit(f"bad digest for {svc}: {digest!r}")
        found[svc] = digest
    return found


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ring", required=True, choices=["ring-canary", "ring-main"])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--digests", help="service=sha256:... lines from the build job")
    src.add_argument("--from-ring", choices=["ring-canary", "ring-main"], help="copy another ring (promotion)")
    a = ap.parse_args()

    header, doc = read_ring(a.ring)
    images = dict(doc.get("images") or {})

    if a.from_ring:
        if a.from_ring == a.ring:
            sys.exit("--from-ring must differ from --ring")
        _, source = read_ring(a.from_ring)
        images = dict(source["images"])
        doc["commit"] = source.get("commit")
    else:
        user = os.environ.get("DOCKERHUB_USER", "").strip()
        if not user:
            sys.exit("DOCKERHUB_USER is not set")
        for svc, digest in parse_digests(a.digests).items():
            images[svc] = f"{user}/cb-{svc}@{digest}"
        doc["commit"] = os.environ.get("GITHUB_SHA", "")[:7] or doc.get("commit")

    missing = [s for s in SERVICES if not REF.match(images.get(s, ""))]
    if missing:
        sys.exit(f"ring {a.ring} would have no valid digest for: {', '.join(missing)}")

    doc["images"] = {s: images[s] for s in SERVICES}
    doc["releasedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = RELEASES / f"{a.ring}.yaml"
    out.write_text(header + yaml.safe_dump(doc, sort_keys=False), encoding="utf-8", newline="\n")
    print(f"updated {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
