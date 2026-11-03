"""One adapter per way of reaching a cell (Strategy). Any read failure is FactUnavailable: unknown, never
a match. Adapters only read; fixing a divergence is a normal PR."""
from __future__ import annotations

import json
import pathlib
import subprocess
from functools import cached_property
from typing import Any, Callable

import yaml

from . import manifests
from .engine import FactUnavailable

Runner = Callable[[list[str]], str]


def run_command(args: list[str]) -> str:
    done = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        raise FactUnavailable(f"{args[0]} exit {done.returncode}: {done.stderr.strip()[:200]}")
    return done.stdout


# Flyway's version column is text, so max(version) would rank 9 above 10. Rank is the applied order.
FLYWAY_SCHEMAS = ("orders", "inventory")
FLYWAY_QUERY = " UNION ALL ".join(
    f"(SELECT '{schema}', version FROM {schema}.flyway_schema_history "
    "WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1)"
    for schema in FLYWAY_SCHEMAS
)


def parse_flyway(rows: str) -> dict[str, str]:
    out = dict(line.split("|", 1) for line in rows.splitlines() if "|" in line)
    if set(out) != set(FLYWAY_SCHEMAS):
        raise FactUnavailable(f"flyway history found for {sorted(out)} only")
    return out


class Facts:
    """What every cell can answer through its Kubernetes API, plus the dispatch."""

    def __init__(self, cell: str, config: dict, contract: dict, run: Runner = run_command):
        self.cell, self.config, self.contract, self.run = cell, config, contract, run

    def get(self, source: str) -> Any:
        reader = getattr(self, "fact_" + source.replace(".", "_"), None)
        if reader is None:
            raise FactUnavailable(f"{type(self).__name__} can't read {source}")
        try:
            return reader()
        except FactUnavailable:
            raise
        except Exception as error:  # a surprise in a reader is still "couldn't read"
            raise FactUnavailable(f"{source}: {type(error).__name__}: {error}") from error

    def kubectl(self, *args: str) -> str:
        return self.run([*self.config["kubectl"], *args])

    def _items(self, namespace: str, kinds: str) -> list[dict]:
        return json.loads(self.kubectl("-n", namespace, "get", kinds, "-o", "json"))["items"]

    @cached_property
    def _app_docs(self) -> list[dict]:
        return self._items("cb-app", "rollouts.argoproj.io,hpa,networkpolicies,configmaps")

    @cached_property
    def _version(self) -> dict:
        return json.loads(self.kubectl("version", "-o", "json"))["serverVersion"]

    @cached_property
    def _terraform(self) -> dict:
        stack = self.config.get("stack")
        if not stack:
            raise FactUnavailable("no Terraform stack for this cell")
        outputs = json.loads(self.run(["terraform", f"-chdir={stack}", "output", "-json"]))
        return {name: output["value"] for name, output in outputs.items()}

    def fact_cluster_k8s_minor(self) -> str:
        return f"{self._version['major']}.{self._version['minor'].rstrip('+')}"

    def fact_workloads_image_digests(self) -> dict:
        return manifests.image_digests(self._app_docs)

    def fact_workloads_requests(self) -> dict:
        return manifests.requests(self._app_docs)

    def fact_workloads_config_hash(self) -> dict:
        return manifests.config_hash(self._app_docs, self.contract.get("config_hash_exclude", []))

    def fact_k8s_hpa_max(self) -> dict:
        return manifests.hpa_max(self._app_docs)

    def fact_k8s_networkpolicy_count(self) -> int:
        return manifests.networkpolicy_count(self._app_docs)

    def fact_argocd_chart_versions(self) -> dict:
        return manifests.chart_versions(self._items("argocd", "applications.argoproj.io"),
                                        self.contract.get("chart_versions_exclude", []))

    def fact_cell_shape(self) -> dict:
        shape = self._terraform["cell"]["shape"]  # the module's row holds both clouds' machine names
        return {key: shape[key] for key in ("vcpu", "mem_gib", "class")}

    def fact_sql_flyway_version(self) -> dict:
        import psycopg  # managed cells only: k3s reads through the pod

        dsn = self.config.get("dsn")
        if not dsn:
            raise FactUnavailable("no database path configured for this cell")
        with psycopg.connect(dsn, connect_timeout=5) as connection:
            rows = connection.execute(FLYWAY_QUERY).fetchall()
        return parse_flyway("\n".join(f"{schema}|{version}" for schema, version in rows))


class K3sFacts(Facts):
    """Budget cells have no database port to reach, so SQL goes through the pod, over its local socket."""

    def _psql(self, query: str) -> str:
        return self.kubectl("-n", "cb-app", "exec", "statefulset/postgres", "--", "sh", "-c",
                            f'psql -U "$POSTGRES_USER" -d cell -AtX -c "{query}"')

    def fact_cluster_k3s_version(self) -> str:
        return self._version["gitVersion"]

    def fact_sql_flyway_version(self) -> dict:
        return parse_flyway(self._psql(FLYWAY_QUERY))

    def fact_database_major(self) -> str:
        return self._psql("SHOW server_version").strip().split(".")[0]

    def fact_cache_major(self) -> str:
        # "valkey-cli 9.0.1": the tool from the image the pod really runs. No password needed.
        output = self.kubectl("-n", "cb-app", "exec", "deployment/valkey", "--", "valkey-cli", "--version")
        return output.split()[1].split(".")[0]


# RDS lists every parameter and Cloud SQL only the flags someone set. Comparing the two raw would diverge
# forever, so each becomes "what someone set, or default".
UNSET = "default"


def _explicit_params(allowed: list[str], explicit: dict[str, Any]) -> dict[str, str]:
    return {name: str(explicit[name]) if name in explicit else UNSET for name in allowed}


class AwsManagedFacts(Facts):
    def __init__(self, cell: str, config: dict, contract: dict, run: Runner = run_command, clients: Callable | None = None):
        super().__init__(cell, config, contract, run)
        self._clients = clients

    def _client(self, service: str):
        if self._clients:
            return self._clients(service)
        import boto3

        return boto3.client(service, region_name=self.config["region"])

    @cached_property
    def _db(self) -> dict:
        return self._client("rds").describe_db_instances(DBInstanceIdentifier=self.cell)["DBInstances"][0]

    def fact_database_major(self) -> str:
        return self._db["EngineVersion"].split(".")[0]

    def fact_database_params(self) -> dict:
        group = self._db["DBParameterGroups"][0]["DBParameterGroupName"]
        explicit = {}
        pages = self._client("rds").get_paginator("describe_db_parameters").paginate(DBParameterGroupName=group)
        for page in pages:
            for parameter in page["Parameters"]:
                if parameter.get("Source") == "user" and "ParameterValue" in parameter:
                    explicit[parameter["ParameterName"]] = parameter["ParameterValue"]
        return _explicit_params(self.contract["pg_params_allowlist"], explicit)

    def fact_cache_major(self) -> str:
        group = self._client("elasticache").describe_replication_groups(ReplicationGroupId=self.cell)["ReplicationGroups"][0]
        clusters = self._client("elasticache").describe_cache_clusters(ShowCacheNodeInfo=False)["CacheClusters"]
        versions = {c["EngineVersion"].split(".")[0] for c in clusters if c["CacheClusterId"] in group["MemberClusters"]}
        if len(versions) != 1:
            raise FactUnavailable(f"cache versions {sorted(versions)}")
        return versions.pop()


class GcpManagedFacts(Facts):
    @cached_property
    def _sql_instance(self) -> dict:
        return json.loads(self.run(["gcloud", "sql", "instances", "describe", self.cell, "--format=json"]))

    def fact_database_major(self) -> str:
        return self._sql_instance["databaseVersion"].split("_")[1]  # POSTGRES_18

    def fact_database_params(self) -> dict:
        flags = self._sql_instance.get("settings", {}).get("databaseFlags", [])
        return _explicit_params(self.contract["pg_params_allowlist"], {f["name"]: f["value"] for f in flags})

    def fact_cache_major(self) -> str:
        output = self.run(["gcloud", "memorystore", "instances", "describe", self.cell,
                           f"--location={self.config['region']}", "--format=value(engineVersion)"])
        return output.strip().split("_")[1]  # VALKEY_9_0


class RenderedFacts:
    """A cell as Git says it should be: helm template output, no cluster needed. It is what a PR can check.
    Sources it can't see aren't in the static contract, so they can't count as matches."""

    SOURCES = ("argocd.chart_versions", "workloads.config_hash", "workloads.requests", "k8s.hpa_max",
               "k8s.networkpolicy_count", "database.major", "cache.major")

    def __init__(self, cell: str, rendered: pathlib.Path, contract: dict):
        self.cell, self.contract = cell, contract
        files = sorted(rendered.glob(f"{cell}--*.yaml"))
        if not files:
            raise FactUnavailable(f"nothing rendered for {cell} in {rendered}")
        self.docs = [doc for f in files for doc in yaml.safe_load_all(f.read_text()) if doc]

    def get(self, source: str) -> Any:
        readers = {
            "argocd.chart_versions": lambda: manifests.chart_versions(self.docs, self.contract.get("chart_versions_exclude", [])),
            "workloads.config_hash": lambda: manifests.config_hash(self.docs, self.contract.get("config_hash_exclude", [])),
            "workloads.requests": lambda: manifests.requests(self.docs),
            "k8s.hpa_max": lambda: manifests.hpa_max(self.docs),
            "k8s.networkpolicy_count": lambda: manifests.networkpolicy_count(self.docs),
            "database.major": lambda: manifests.image_major(self.docs, "postgres"),
            "cache.major": lambda: manifests.image_major(self.docs, "valkey"),
        }
        try:
            return readers[source]()
        except KeyError as error:
            raise FactUnavailable(f"{source}: {error}") from error


ADAPTERS = {"k3s": K3sFacts, "aws-managed": AwsManagedFacts, "gcp-managed": GcpManagedFacts}
