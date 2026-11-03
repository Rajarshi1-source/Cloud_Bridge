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
    "attribute.event_name"  = "assertion.event_name"
    "attribute.ref"         = "assertion.ref"
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

# ---- Plan and apply identities (iac-pr, iac-apply, drift)

locals {
  wif_pool = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
}

resource "google_service_account" "plan" {
  project      = var.gcp_project_id
  account_id   = "cb-plan-gcp"
  display_name = "iac-pr, iac-apply and drift: read-only terraform plan"
}

resource "google_service_account_iam_member" "plan_wif" {
  for_each = toset([
    "attribute.event_name/pull_request",
    "attribute.ref/refs/heads/main",
  ])
  service_account_id = google_service_account.plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_pool}/${each.value}"
}

resource "google_project_iam_member" "plan_viewer" {
  project = var.gcp_project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.plan.email}"
}

resource "google_storage_bucket_iam_member" "plan_state_list" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.plan.email}"
}

# Every state except the origin certificate's, which holds a private key no plan needs to read.
resource "google_storage_bucket_iam_member" "plan_state_read" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.plan.email}"
  condition {
    title      = "all-state-except-origin-tls"
    expression = "!resource.name.startsWith(\"projects/_/buckets/${var.gcp_state_bucket}/objects/global/origin-tls\")"
  }
}

# The GCS backend takes its lock by writing a .tflock object, even during a plan.
resource "google_storage_bucket_iam_member" "plan_state_lock" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.plan.email}"
  condition {
    title      = "lock-files-only"
    expression = "resource.name.endsWith(\".tflock\")"
  }
}

resource "google_service_account" "apply_budget" {
  project      = var.gcp_project_id
  account_id   = "cb-apply-gcp-budget"
  display_name = "iac-apply: apply a reviewed plan of gcp-budget"
}

resource "google_service_account_iam_member" "apply_budget_wif" {
  service_account_id = google_service_account.apply_budget.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_pool}/attribute.environment/gcp-budget"
}

# What the gcp-budget cell creates: network and NAT, the VM, its address and firewall, its service account.
resource "google_project_iam_member" "apply_budget" {
  for_each = toset([
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.apply_budget.email}"
}

resource "google_storage_bucket_iam_member" "apply_budget_state_list" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.apply_budget.email}"
}

resource "google_storage_bucket_iam_member" "apply_budget_state" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.apply_budget.email}"
  condition {
    title      = "gcp-budget-state-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.gcp_state_bucket}/objects/gcp-budget/\")"
  }
}

# The traffic stack: Cloudflare is the only thing it changes (token in environment traffic-prod), and in
# GCP it only touches its own state and reads the GCP cell's.
resource "google_service_account" "apply_traffic" {
  project      = var.gcp_project_id
  account_id   = "cb-apply-traffic"
  display_name = "iac-apply: apply a reviewed plan of global/30-traffic"
}

resource "google_service_account_iam_member" "apply_traffic_wif" {
  service_account_id = google_service_account.apply_traffic.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_pool}/attribute.environment/traffic-prod"
}

resource "google_storage_bucket_iam_member" "apply_traffic_state_list" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.apply_traffic.email}"
}

resource "google_storage_bucket_iam_member" "apply_traffic_state" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.apply_traffic.email}"
  condition {
    title      = "traffic-state-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.gcp_state_bucket}/objects/global/traffic/\")"
  }
}

resource "google_storage_bucket_iam_member" "apply_traffic_cell_state" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.apply_traffic.email}"
  condition {
    title      = "gcp-budget-state-read"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.gcp_state_bucket}/objects/gcp-budget/\")"
  }
}
