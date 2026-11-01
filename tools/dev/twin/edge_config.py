#!/usr/bin/env python3
"""Render the twin edge's Traefik config from the same files the Cloudflare stack reads.

The weights come from infra/live/global/30-traffic/terraform.tfvars.json and the hostname from
gitops/global/values.yaml, so a weight change is made exactly as in production (edit the tfvars
file) and the edge follows within seconds (Traefik watches the output file).

Cloudflare behaviour it reproduces:
  - random steering by pool weight; a 0-weight cell gets no traffic (it is drained)
  - cookie affinity (__cflb, Secure, SameSite=Lax): a user's reads stay on the cell of their writes
  - the /healthz/cell monitor with the app hostname as Host header; an unhealthy cell leaves the
    rotation, and when every weighted cell is down the fallback cell takes everything
  - Full (strict) TLS to the origin, verified against the twin's origin CA
Differences, on purpose: the monitor runs every 10 s instead of 60 s and from one place instead of
two regions, so drills finish in seconds; there is no Access in front of admin-<cloud> hosts yet.

    python3 edge_config.py <repo> <out.yaml>
Output is JSON, which Traefik's file provider reads as YAML.
"""
import json
import re
import sys
from pathlib import Path

CELLS = {"aws": "cb-aws-local", "gcp": "cb-gcp-local"}
FALLBACK = "gcp"  # var.fallback_cell default in 30-traffic/variables.tf


def load(repo: Path) -> tuple[str, dict[str, int]]:
    values = (repo / "gitops/global/values.yaml").read_text()
    domain = re.search(r"^domain:\s*(\S+)", values, re.M).group(1)
    weights = json.loads((repo / "infra/live/global/30-traffic/terraform.tfvars.json").read_text())["weights"]
    # The same three rules as variable "weights" in 30-traffic: a file Terraform would reject must
    # not quietly work in the twin.
    if set(weights) != set(CELLS):
        sys.exit(f"weights need exactly the keys {sorted(CELLS)}, got {sorted(weights)}")
    if sum(weights.values()) != 100:
        sys.exit(f"weights must sum to 100, got {sum(weights.values())}")
    if any(w != 0 and w < 10 for w in weights.values()):
        sys.exit("each cell must be 0 (drained) or >= 10 (warm floor)")
    return domain, weights


def render(domain: str, weights: dict[str, int]) -> dict:
    host = f"app.{domain}"
    services = {
        f"cell-{cloud}": {
            "loadBalancer": {
                "servers": [{"url": f"https://cell-{cloud}:443"}],
                "passHostHeader": True,
                "serversTransport": "origin",
                "healthCheck": {
                    "path": "/healthz/cell",
                    "hostname": host,
                    "interval": "10s",
                    "timeout": "5s",
                },
            }
        }
        for cloud in CELLS
    }
    weighted = [{"name": f"cell-{c}", "weight": w} for c, w in sorted(weights.items()) if w > 0]
    services["weighted"] = {
        "weighted": {
            "services": weighted,
            "sticky": {
                "cookie": {"name": "__cflb", "secure": True, "httpOnly": True, "sameSite": "lax"}
            },
            "healthCheck": {},  # report down when every weighted cell is down, so failover kicks in
        }
    }
    services["app"] = {
        "failover": {"service": "weighted", "fallback": f"cell-{FALLBACK}", "healthCheck": {}}
    }
    return {
        "http": {
            "routers": {
                "app": {
                    "rule": f"Host(`{host}`)",
                    "entryPoints": ["websecure"],
                    "service": "app",
                    "tls": {},
                }
            },
            "services": services,
            "serversTransports": {
                "origin": {"serverName": host, "rootCAs": ["/pki/ca.crt"]}
            },
        },
        "tls": {
            "certificates": [{"certFile": "/pki/edge.crt", "keyFile": "/pki/edge.key"}],
        },
    }


def main() -> None:
    repo, out = Path(sys.argv[1]), Path(sys.argv[2])
    domain, weights = load(repo)
    tmp = out.with_suffix(".tmp")
    tmp.write_text(json.dumps(render(domain, weights), indent=2) + "\n")
    tmp.replace(out)  # atomic: Traefik never reads a half-written file
    print(f"edge: app.{domain} " + " ".join(f"{c}={w}" for c, w in sorted(weights.items())))


if __name__ == "__main__":
    main()
