# Offline: both clouds mocked. Proves each identity's trust is pinned to this repository and to the
# one environment it serves, plans stay read-only, and state access is limited to each stack.
mock_provider "aws" {
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    }
  }
}

mock_provider "google" {
  # The provider validates service_account_id as a full resource name.
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/cb-test-project/serviceAccounts/cb-ephemeral-gcp@cb-test-project.iam.gserviceaccount.com"
      email = "cb-ephemeral-gcp@cb-test-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  gcp_project_id = "cb-test-project"
}

run "trust_is_one_repo_one_environment" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.ephemeral.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Rajarshi1-source/Cloud_Bridge:environment:ephemeral"
    error_message = "The AWS role must trust only this repository's ephemeral environment."
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == 'Rajarshi1-source/Cloud_Bridge'"
    error_message = "The WIF provider must admit only this repository."
  }
  assert {
    condition     = endswith(google_service_account_iam_member.ephemeral_wif.member, "/attribute.environment/ephemeral")
    error_message = "The GCP service account must admit only the ephemeral environment."
  }
  assert {
    condition     = strcontains(google_storage_bucket_iam_member.ephemeral_state.condition[0].expression, "/objects/gcp-dev/")
    error_message = "GCS state access must be limited to the gcp-dev stack."
  }
}

run "plan_identities_are_read_only_and_apply_identities_need_an_environment" {
  command = apply

  assert {
    condition = toset(jsondecode(aws_iam_role.plan.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]) == toset([
      "repo:Rajarshi1-source/Cloud_Bridge:pull_request",
      "repo:Rajarshi1-source/Cloud_Bridge:ref:refs/heads/main",
      "repo:Rajarshi1-source/Cloud_Bridge:environment:traffic-prod",
    ])
    error_message = "The plan role must trust PRs, main and the read-only traffic apply, and nothing else."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The plan role must be read-only."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.plan_state_lock.policy).Statement[0].Resource == "arn:aws:s3:::cb-tfstate-aws/*.tflock"
    error_message = "The plan role may write lock files only, never state."
  }
  assert {
    condition     = jsondecode(aws_iam_role.apply_budget.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:Rajarshi1-source/Cloud_Bridge:environment:aws-budget"
    error_message = "The apply role must trust only its protected environment."
  }
  assert {
    condition     = endswith(google_service_account_iam_member.apply_budget_wif.member, "/attribute.environment/gcp-budget")
    error_message = "The GCP apply account must admit only its protected environment."
  }
  assert {
    condition     = endswith(google_service_account_iam_member.apply_traffic_wif.member, "/attribute.environment/traffic-prod")
    error_message = "The traffic account must admit only traffic-prod."
  }
  assert {
    condition     = google_project_iam_member.plan_viewer.role == "roles/viewer"
    error_message = "The GCP plan account must be a viewer."
  }
  assert {
    condition     = startswith(google_storage_bucket_iam_member.plan_state_read.condition[0].expression, "!") && strcontains(google_storage_bucket_iam_member.plan_state_read.condition[0].expression, "origin-tls")
    error_message = "The plan account must never read the origin certificate's state."
  }
  assert {
    condition     = strcontains(google_storage_bucket_iam_member.apply_budget_state.condition[0].expression, "/objects/gcp-budget/")
    error_message = "The budget apply account may only write its own state."
  }
}
