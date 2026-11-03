"""The adapters on fixtures shaped like the real API answers. Real AWS, GCP and k3s reads aren't exercised
here: tools/dev/twin/parity.sh covers K3sFacts on live cells; RDS, ElastiCache and gcloud have never run."""
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from parity import manifests  # noqa: E402
from parity.engine import FactUnavailable, evaluate  # noqa: E402
from parity.facts import AwsManagedFacts, FLYWAY_QUERY, GcpManagedFacts, K3sFacts, RenderedFacts, parse_flyway  # noqa: E402

CONTRACT = {
    "config_hash_exclude": ["CB_CELL", "CB_ADMIN_HOST"],
    "chart_versions_exclude": ["aws-load-balancer-controller"],
    "pg_params_allowlist": ["max_connections", "statement_timeout", "work_mem"],
}


def rollout(name="api-gateway", image="u/x@sha256:aaa", env=None, cpu="100m"):
    return {"kind": "Rollout", "metadata": {"name": name}, "spec": {"template": {"spec": {"containers": [{
        "image": image, "env": env or [{"name": "CB_CELL", "value": "one"}, {"name": "A", "value": "1"}],
        "resources": {"requests": {"cpu": cpu}},
    }]}}}}


class Manifests(unittest.TestCase):
    def test_mirror_prefix_is_not_a_difference(self):
        a = manifests.image_digests([rollout(image="ecr.example/dockerhub/u/x@sha256:aaa")])
        b = manifests.image_digests([rollout(image="ar.example/dockerhub/u/x@sha256:aaa")])
        self.assertEqual(a, b)

    def test_a_tag_is_not_a_fact(self):
        with self.assertRaises(FactUnavailable):
            manifests.image_digests([rollout(image="u/x:latest")])

    def test_config_hash_ignores_the_allowed_per_cell_names_only(self):
        same = rollout(env=[{"name": "CB_CELL", "value": "two"}, {"name": "A", "value": "1"}])
        changed = rollout(env=[{"name": "CB_CELL", "value": "one"}, {"name": "A", "value": "2"}])
        hash_of = lambda doc: manifests.config_hash([doc], CONTRACT["config_hash_exclude"])
        self.assertEqual(hash_of(rollout()), hash_of(same))
        self.assertNotEqual(hash_of(rollout()), hash_of(changed))

    def test_a_secret_reference_is_hashed_and_its_value_is_never_seen(self):
        by_key = lambda key: rollout(env=[{"name": "P", "valueFrom": {"secretKeyRef": {"name": "cell-db", "key": key}}}])
        hash_of = lambda doc: manifests.config_hash([doc], [])
        self.assertNotEqual(hash_of(by_key("password")), hash_of(by_key("other")))

    def test_chart_versions_upstream_and_this_repo(self):
        apps = [
            {"kind": "Application", "metadata": {"name": "traefik"}, "spec": {"source": {"chart": "traefik", "targetRevision": "41.7.1"}}},
            {"kind": "Application", "metadata": {"name": "aws-load-balancer-controller"}, "spec": {"source": {"chart": "x", "targetRevision": "1"}}},
            {"kind": "Application", "metadata": {"name": "api-gateway"}, "spec": {"sources": [
                {"path": "gitops/charts/api-gateway", "targetRevision": "main"}, {"ref": "values", "targetRevision": "main"}]}},
        ]
        self.assertEqual(manifests.chart_versions(apps, CONTRACT["chart_versions_exclude"]),
                         {"traefik": "traefik@41.7.1", "api-gateway": "gitops/charts/api-gateway@main"})

    def test_no_network_policy_is_unreadable_not_zero(self):
        with self.assertRaises(FactUnavailable):
            manifests.networkpolicy_count([rollout()])


def fake_kubectl(answers):
    def run(args):
        key = next((k for k in answers if k in " ".join(args)), None)
        if key is None:
            raise FactUnavailable(f"exit 1: {args}")
        return answers[key]
    return run


class K3s(unittest.TestCase):
    def facts(self, answers):
        return K3sFacts("cb-aws-local", {"kubectl": ["kubectl"], "stack": ""}, CONTRACT, run=fake_kubectl(answers))

    def test_versions_from_the_api_server(self):
        facts = self.facts({"version": json.dumps({"serverVersion": {"major": "1", "minor": "36+", "gitVersion": "v1.36.5+k3s1"}})})
        self.assertEqual(facts.get("cluster.k8s_minor"), "1.36")
        self.assertEqual(facts.get("cluster.k3s_version"), "v1.36.5+k3s1")

    def test_postgres_and_valkey_go_through_the_pod(self):
        facts = self.facts({"SHOW server_version": "18.4\n", "valkey-cli": "valkey-cli 9.0.1\n",
                            "flyway_schema_history": "orders|2\ninventory|10\n"})
        self.assertEqual(facts.get("database.major"), "18")
        self.assertEqual(facts.get("cache.major"), "9")
        self.assertEqual(facts.get("sql.flyway_version"), {"orders": "2", "inventory": "10"})

    def test_flyway_never_compares_text_versions(self):
        self.assertNotIn("max(version)", FLYWAY_QUERY)
        self.assertIn("installed_rank DESC", FLYWAY_QUERY)

    def test_a_schema_with_no_history_is_unknown(self):
        with self.assertRaises(FactUnavailable):
            parse_flyway("orders|2\n")

    def test_an_unreachable_cell_is_unknown_for_every_check(self):
        facts = self.facts({})
        for source in ("cluster.k8s_minor", "workloads.image_digests", "database.major", "cache.major", "cell.shape"):
            with self.assertRaises(FactUnavailable):
                facts.get(source)

    def test_a_garbled_answer_is_unknown_not_a_crash(self):
        with self.assertRaises(FactUnavailable):
            self.facts({"version": "not json"}).get("cluster.k8s_minor")


class FakeRds:
    def describe_db_instances(self, DBInstanceIdentifier):
        return {"DBInstances": [{"EngineVersion": "18.4", "DBParameterGroups": [{"DBParameterGroupName": "cb"}]}]}

    def get_paginator(self, _):
        return self

    def paginate(self, DBParameterGroupName):
        # RDS lists everything: formulas and system defaults aren't someone's choice.
        return [{"Parameters": [
            {"ParameterName": "max_connections", "ParameterValue": "LEAST({DBInstanceClassMemory/9531392},5000)", "Source": "system"},
            {"ParameterName": "work_mem", "ParameterValue": "8192", "Source": "user"},
            {"ParameterName": "statement_timeout", "Source": "engine-default"},
            {"ParameterName": "unrelated", "ParameterValue": "1", "Source": "user"},
        ]}]


class FakeElastiCache:
    def describe_replication_groups(self, ReplicationGroupId):
        return {"ReplicationGroups": [{"MemberClusters": ["cb-aws-prod-001", "cb-aws-prod-002"]}]}

    def describe_cache_clusters(self, ShowCacheNodeInfo):
        return {"CacheClusters": [
            {"CacheClusterId": "cb-aws-prod-001", "EngineVersion": "9.0.1"},
            {"CacheClusterId": "cb-aws-prod-002", "EngineVersion": "9.0.1"},
            {"CacheClusterId": "other-001", "EngineVersion": "7.2.4"},
        ]}


class Managed(unittest.TestCase):
    def aws(self):
        clients = {"rds": FakeRds(), "elasticache": FakeElastiCache()}
        return AwsManagedFacts("cb-aws-prod", {"kubectl": ["kubectl"], "region": "ap-south-1"}, CONTRACT, clients=clients.__getitem__)

    def gcp(self, flags):
        sql = json.dumps({"databaseVersion": "POSTGRES_18", "settings": {"databaseFlags": flags}})
        run = fake_kubectl({"sql instances": sql, "memorystore": "VALKEY_9_0\n"})
        return GcpManagedFacts("cb-gcp-prod", {"kubectl": ["kubectl"], "region": "asia-south1"}, CONTRACT, run=run)

    def test_both_clouds_report_majors_the_same_way(self):
        aws, gcp = self.aws(), self.gcp([])
        self.assertEqual(aws.get("database.major"), gcp.get("database.major"))
        self.assertEqual(aws.get("cache.major"), gcp.get("cache.major"))

    def test_rds_and_cloud_sql_params_compare_on_what_someone_set(self):
        aws, same, other = self.aws(), self.gcp([{"name": "work_mem", "value": "8192"}]), self.gcp([{"name": "work_mem", "value": "4096"}])
        self.assertEqual(aws.get("database.params"), same.get("database.params"))
        self.assertNotEqual(aws.get("database.params"), other.get("database.params"))
        self.assertEqual(aws.get("database.params")["max_connections"], "default")

    def test_mixed_cache_versions_are_unknown(self):
        aws = self.aws()
        aws._client("elasticache").describe_cache_clusters = lambda ShowCacheNodeInfo: {"CacheClusters": [
            {"CacheClusterId": "cb-aws-prod-001", "EngineVersion": "9.0.1"},
            {"CacheClusterId": "cb-aws-prod-002", "EngineVersion": "8.1.0"}]}
        with self.assertRaises(FactUnavailable):
            aws.get("cache.major")

    def test_shape_ignores_each_clouds_machine_name(self):
        outputs = lambda machine: json.dumps({"cell": {"value": {"shape": {"vcpu": 2, "mem_gib": 4, "class": "burstable", "aws": machine}}}})
        one = GcpManagedFacts("a", {"kubectl": [], "stack": "s", "region": "r"}, CONTRACT, run=fake_kubectl({"terraform": outputs("x")}))
        two = GcpManagedFacts("b", {"kubectl": [], "stack": "s", "region": "r"}, CONTRACT, run=fake_kubectl({"terraform": outputs("y")}))
        self.assertEqual(one.get("cell.shape"), two.get("cell.shape"))


class Rendered(unittest.TestCase):
    def test_a_cell_with_nothing_rendered_fails_loudly(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(FactUnavailable):
            RenderedFacts("cb-aws-budget", pathlib.Path(directory), CONTRACT)

    def test_static_mode_sees_a_chart_version_changed_in_one_cell(self):
        template = """kind: Application
metadata: {{name: traefik}}
spec: {{source: {{chart: traefik, targetRevision: "{version}"}}}}
"""
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / "cb-aws-budget--platform-addons.yaml").write_text(template.format(version="41.7.2"))
            (path / "cb-gcp-budget--platform-addons.yaml").write_text(template.format(version="41.7.1"))
            facts = [RenderedFacts(c, path, CONTRACT) for c in ("cb-aws-budget", "cb-gcp-budget")]
            contract = {"checks": [{"id": "chart.versions", "source": "argocd.chart_versions", "weight": 3}]}
            result = evaluate(contract, facts, [])
        self.assertFalse(result.passed)
        self.assertEqual(result.findings[0].status, "diverged")

    def test_one_cell_can_not_be_compared_with_itself(self):
        with self.assertRaises(ValueError):
            evaluate({"checks": []}, [object()], [])


if __name__ == "__main__":
    unittest.main()
