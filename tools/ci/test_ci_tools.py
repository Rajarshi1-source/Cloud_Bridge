"""python3 -m unittest discover -s tools/ci -p 'test_*.py'"""
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import affected_stacks  # noqa: E402
import plan_report  # noqa: E402
import render_pr_comment  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]


class AffectedStacks(unittest.TestCase):
    def names(self, *files):
        return [s["name"] for s in affected_stacks.affected(list(files), ROOT)["stacks"]]

    def test_a_shared_module_affects_both_clouds_gcp_first(self):
        self.assertEqual(self.names("infra/modules/cell/main.tf"), ["gcp-budget/10-foundation", "aws-budget/10-foundation"])

    def test_one_clouds_implementation_plans_both_because_the_facade_holds_both(self):
        self.assertEqual(self.names("infra/modules/cluster/k3s-vm-aws/main.tf"), ["gcp-budget/10-foundation", "aws-budget/10-foundation"])

    def test_weights_file_affects_traffic_only(self):
        result = affected_stacks.affected(["infra/live/global/30-traffic/terraform.tfvars.json"], ROOT)
        self.assertEqual([s["name"] for s in result["stacks"]], ["global/30-traffic"])
        self.assertEqual(result["stacks"][0]["env"], "traffic-prod")

    def test_the_domain_file_affects_traffic(self):
        self.assertEqual(self.names("gitops/global/values.yaml"), ["global/30-traffic"])

    def test_identity_and_dev_stacks_are_affected_but_never_planned(self):
        result = affected_stacks.affected(["infra/live/global/00-ci-identity/aws.tf", "infra/live/aws-dev/10-foundation/main.tf"], ROOT)
        self.assertEqual(result["stacks"], [])
        self.assertIn("infra/live/global/00-ci-identity", result["not_planned"])
        self.assertIn("infra/live/aws-dev/10-foundation", result["not_planned"])

    def test_unrelated_files_affect_nothing(self):
        self.assertEqual(self.names("docs/README.md", "services/api-gateway/pom.xml"), [])


class PlanReport(unittest.TestCase):
    def test_a_replace_counts_as_add_and_destroy(self):
        plan = {"resource_changes": [
            {"change": {"actions": ["create"]}},
            {"change": {"actions": ["update"]}},
            {"change": {"actions": ["delete", "create"]}},
            {"change": {"actions": ["no-op"]}},
        ]}
        self.assertEqual(plan_report.counts(plan), {"add": 2, "change": 1, "destroy": 1})


class Comment(unittest.TestCase):
    def write(self, root, name, report=None, conftest=None, infracost=None):
        directory = root / name
        directory.mkdir(parents=True)
        for file, value in (("report.json", report), ("conftest.json", conftest), ("infracost.json", infracost)):
            if value is not None:
                (directory / file).write_text(json.dumps(value), encoding="utf-8")

    def test_both_plans_cost_and_policy_appear_in_one_comment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for cloud, delta in (("aws", "4.25"), ("gcp", "-1.5")):
                self.write(
                    root, f"report-{cloud}",
                    {"stack": f"infra/live/{cloud}-budget/10-foundation", "cloud": cloud, "status": "planned",
                     "counts": {"add": 3, "change": 1, "destroy": 0}, "plan_sha256": "ab" * 32},
                    [{"filename": "plan.json", "failures": []}],
                    {"diffTotalMonthlyCost": delta, "currency": "USD"},
                )
            comment, failed = render_pr_comment.render(root)
        self.assertEqual(failed, 0)
        self.assertIn("infra/live/aws-budget/10-foundation", comment)
        self.assertIn("infra/live/gcp-budget/10-foundation", comment)
        self.assertIn("+3 ~1 -0", comment)
        self.assertIn("+4.25 USD/mo", comment)
        self.assertIn("-1.50 USD/mo", comment)
        self.assertIn("✅ pass", comment)

    def test_a_policy_failure_fails_the_job_and_names_the_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.write(root, "report-aws", {"stack": "s", "cloud": "aws", "status": "planned",
                                            "counts": {"add": 1, "change": 0, "destroy": 0}},
                       [{"failures": [{"msg": "aws_instance.vm is missing labels/tags"}]}])
            comment, failed = render_pr_comment.render(root)
        self.assertEqual(failed, 1)
        self.assertIn("⛔ 1 failed", comment)
        self.assertIn("aws_instance.vm is missing labels/tags", comment)

    def test_a_change_in_only_one_clouds_plan_is_called_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.write(root, "report-aws", {"stack": "a", "cloud": "aws", "status": "planned", "counts": {"add": 1, "change": 0, "destroy": 0}})
            self.write(root, "report-gcp", {"stack": "g", "cloud": "gcp", "status": "planned", "counts": {"add": 0, "change": 0, "destroy": 0}})
            comment, _ = render_pr_comment.render(root)
        self.assertIn("One-sided change", comment)

    def test_what_was_not_measured_is_never_shown_as_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            self.write(root, "report-gcp", {"stack": "s", "cloud": "gcp", "status": "skipped", "reason": "CI identity not configured"})
            comment, failed = render_pr_comment.render(root)
        self.assertEqual(failed, 0)
        self.assertIn("not planned: CI identity not configured", comment)
        self.assertEqual(comment.count("not measured"), 2)
        self.assertNotIn("0.00", comment)


if __name__ == "__main__":
    unittest.main()
