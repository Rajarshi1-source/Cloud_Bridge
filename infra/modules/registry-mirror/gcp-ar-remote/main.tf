# Artifact Registry remote repository for Docker Hub: nodes pull <region>-docker.pkg.dev/<project>/
# dockerhub/<user>/cb-<svc>@sha256:…; the node service account already has artifactregistry.reader.

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "dockerhub_user" {
  type        = string
  default     = null
  description = "Docker ID for authenticated upstream pulls (token = latest version of secret cb-dockerhub-pull). Null = anonymous, rate-limited."
}

variable "labels" {
  type = map(string)
}

data "google_project" "this" {
  project_id = var.project_id
}

data "google_secret_manager_secret" "dockerhub" {
  count     = var.dockerhub_user == null ? 0 : 1
  project   = var.project_id
  secret_id = "cb-dockerhub-pull"
}

# The Artifact Registry service agent reads the upstream token.
resource "google_secret_manager_secret_iam_member" "ar_reads_token" {
  count     = var.dockerhub_user == null ? 0 : 1
  project   = var.project_id
  secret_id = data.google_secret_manager_secret.dockerhub[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository" "dockerhub" {
  project       = var.project_id
  location      = var.region
  repository_id = "dockerhub"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Docker Hub pull-through for CloudBridge images"
  labels        = var.labels

  remote_repository_config {
    description = "Docker Hub"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
    dynamic "upstream_credentials" {
      for_each = var.dockerhub_user == null ? [] : [1]
      content {
        username_password_credentials {
          username                = var.dockerhub_user
          password_secret_version = "${data.google_secret_manager_secret.dockerhub[0].id}/versions/latest"
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.ar_reads_token]
}

output "prefix" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub.repository_id}"
}
