# What External Secrets reads on GCP: the cell's connection settings, and (when Postgres runs in the
# cluster) its password. The controller's Kubernetes service account is granted read access directly
# through Workload Identity Federation, limited to this cell's secrets and the origin certificate.
variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "config" {
  type      = map(string)
  sensitive = true
}

variable "in_cluster_db" {
  type = bool
}

variable "labels" {
  type = map(string)
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_secret_manager_secret" "config" {
  project   = var.project_id
  secret_id = "${var.name}-cell-config"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "config" {
  secret      = google_secret_manager_secret.config.id
  secret_data = jsonencode(var.config)
}

resource "random_password" "in_cluster_db" {
  count   = var.in_cluster_db ? 1 : 0
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "in_cluster_db" {
  count     = var.in_cluster_db ? 1 : 0
  project   = var.project_id
  secret_id = "${var.name}-db-admin"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "in_cluster_db" {
  count       = var.in_cluster_db ? 1 : 0
  secret      = google_secret_manager_secret.in_cluster_db[0].id
  secret_data = jsonencode({ username = "cell", password = random_password.in_cluster_db[0].result })
}

locals {
  pool   = "${var.project_id}.svc.id.goog"
  reader = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${local.pool}/subject/ns/external-secrets/sa/external-secrets"
  secret = "projects/${data.google_project.this.number}/secrets"
}

resource "google_project_iam_member" "read_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = local.reader
  condition {
    title      = "${var.name}-cell-secrets"
    expression = "resource.name.startsWith(\"${local.secret}/${var.name}-\") || resource.name.startsWith(\"${local.secret}/cb-origin-tls\")"
  }
}

output "secret_store" {
  value = {
    kind   = "gcp"
    prefix = var.name
    reader = local.reader
  }
}
