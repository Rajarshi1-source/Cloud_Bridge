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
