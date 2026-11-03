"""Facts from Kubernetes objects. A live cell's API and a rendered chart give the same shapes, so both
modes compute a fact the same way."""
from __future__ import annotations

import hashlib
import json
from typing import Any, Iterable

from .engine import FactUnavailable

Doc = dict[str, Any]


def of_kind(docs: Iterable[Doc], kind: str) -> list[Doc]:
    return [d for d in docs if d and d.get("kind") == kind]


def _app_container(rollout: Doc) -> Doc:
    return rollout["spec"]["template"]["spec"]["containers"][0]


def image_digests(docs: Iterable[Doc]) -> dict[str, str]:
    out = {}
    for rollout in of_kind(docs, "Rollout"):
        image = _app_container(rollout)["image"]
        if "@sha256:" not in image:
            raise FactUnavailable(f"{rollout['metadata']['name']} isn't pinned by digest: {image}")
        out[rollout["metadata"]["name"]] = image.split("@", 1)[1]  # the mirror prefix differs by design
    return out


def requests(docs: Iterable[Doc]) -> dict[str, dict]:
    return {r["metadata"]["name"]: _app_container(r).get("resources", {}).get("requests", {})
            for r in of_kind(docs, "Rollout")}


def hpa_max(docs: Iterable[Doc]) -> dict[str, int]:
    return {h["metadata"]["name"]: h["spec"]["maxReplicas"] for h in of_kind(docs, "HorizontalPodAutoscaler")}


def networkpolicy_count(docs: Iterable[Doc]) -> int:
    count = len(of_kind(docs, "NetworkPolicy"))
    if not count:  # both cells at zero would match, with default-deny gone from both
        raise FactUnavailable("no NetworkPolicy found")
    return count


def config_hash(docs: Iterable[Doc], exclude: Iterable[str]) -> dict[str, str]:
    """Config here is each workload's environment, plus any ConfigMap. Secret values never enter: only
    which Secret and key a variable points at."""
    excluded = set(exclude)
    out = {}
    for rollout in of_kind(docs, "Rollout"):
        container = _app_container(rollout)
        env = sorted((e for e in container.get("env", []) if e["name"] not in excluded), key=lambda e: e["name"])
        payload = {"env": env, "args": container.get("args"), "command": container.get("command")}
        out[rollout["metadata"]["name"]] = _digest(payload)
    for config_map in of_kind(docs, "ConfigMap"):
        name = config_map["metadata"]["name"]
        if name == "kube-root-ca.crt" or config_map["metadata"].get("namespace", "cb-app") != "cb-app":
            continue
        data = {k: v for k, v in (config_map.get("data") or {}).items() if k not in excluded}
        out[f"configmap/{name}"] = _digest(data)
    return out


def _digest(payload: Any) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()[:16]


def chart_versions(applications: Iterable[Doc], exclude: Iterable[str]) -> dict[str, str]:
    """chart@version for upstream charts, path@revision for this repo's. Not the synced commit: two
    healthy cells sit a poll apart, and that isn't drift."""
    excluded = set(exclude)
    out = {}
    for app in of_kind(applications, "Application"):
        name = app["metadata"]["name"]
        if name in excluded:
            continue
        spec = app["spec"]
        sources = spec.get("sources") or [spec["source"]]
        out[name] = ",".join(sorted(
            f"{s.get('chart') or s.get('path')}@{s.get('targetRevision')}" for s in sources if s.get("chart") or s.get("path")))
    return out


def image_major(docs: Iterable[Doc], workload: str) -> str:
    """Rendered charts only: the major in the tag of a data service's image."""
    for doc in docs:
        if doc and doc.get("kind") in ("StatefulSet", "Deployment") and doc["metadata"]["name"] == workload:
            image = doc["spec"]["template"]["spec"]["containers"][0]["image"]
            return image.rsplit(":", 1)[1].split(".")[0].split("-")[0]
    raise FactUnavailable(f"no {workload} workload rendered")
