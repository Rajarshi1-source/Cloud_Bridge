# GitHub Actions → GCP through Workload Identity Federation. The provider admits tokens from one
# repository only; the service account admits only the "ephemeral" environment of that repository.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "cloudbridge"
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.environment" = "assertion.environment"
  }
  attribute_condition = "assertion.repository == '${var.github_repository}'"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ephemeral" {
  project      = var.gcp_project_id
  account_id   = "cb-ephemeral-gcp"
  display_name = "ephemeral-up.yml and ttl-reaper.yml (gcp-dev cell)"
}

resource "google_service_account_iam_member" "ephemeral_wif" {
  service_account_id = google_service_account.ephemeral.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/ephemeral"
}

# What the gcp-dev cell creates: network + NAT, GKE, its node service account and that account's
# project roles, the Artifact Registry remote repository (and its read of the pull token).
# projectIamAdmin is the broad one: GKE's node account needs project-level role grants.
resource "google_project_iam_member" "ephemeral" {
  for_each = toset([
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
  ])
  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ephemeral.email}"
}

# Listing objects is a bucket-level permission, which an object-name condition never matches; this
# legacy role grants list (and bucket metadata) without reading any object, e.g. the origin key's state.
resource "google_storage_bucket_iam_member" "ephemeral_state_list" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.ephemeral.email}"
}

resource "google_storage_bucket_iam_member" "ephemeral_state" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ephemeral.email}"
  condition {
    title      = "gcp-dev-state-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.gcp_state_bucket}/objects/gcp-dev/\")"
  }
}
