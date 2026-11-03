# Set these as variables of the GitHub environment "ephemeral" (Settings → Environments).
output "AWS_EPHEMERAL_ROLE" {
  value = aws_iam_role.ephemeral.arn
}

output "GCP_WIF_PROVIDER" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "GCP_EPHEMERAL_SA" {
  value = google_service_account.ephemeral.email
}

# Repository variables.
output "AWS_PLAN_ROLE" {
  value = aws_iam_role.plan.arn
}

output "GCP_PLAN_SA" {
  value = google_service_account.plan.email
}

# Variables of the GitHub environments (docs/runbooks/iac-pipeline.md).
output "apply_identities" {
  value = {
    aws-budget   = { AWS_APPLY_ROLE = aws_iam_role.apply_budget.arn }
    gcp-budget   = { GCP_APPLY_SA = google_service_account.apply_budget.email }
    traffic-prod = { AWS_APPLY_ROLE = aws_iam_role.plan.arn, GCP_APPLY_SA = google_service_account.apply_traffic.email }
  }
}
