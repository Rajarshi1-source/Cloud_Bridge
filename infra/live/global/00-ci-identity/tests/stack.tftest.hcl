# Offline: both clouds mocked. Proves the trust is pinned to this repository's "ephemeral"
# environment and that the state access is limited to the dev stacks.
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
