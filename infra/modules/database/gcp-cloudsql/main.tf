variable "name" {
  type = string
}

variable "env" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network" {
  type = string
}

variable "database_version" {
  type = string
}

variable "labels" {
  type = map(string)
}

resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${var.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = var.network
}

resource "google_service_networking_connection" "psa" {
  network                 = var.network
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

resource "random_password" "admin" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "db" {
  project   = var.project_id
  secret_id = "${var.name}-db-admin"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db" {
  secret      = google_secret_manager_secret.db.id
  secret_data = random_password.admin.result
}

resource "google_sql_database_instance" "this" {
  project             = var.project_id
  name                = var.name
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.env == "prod"
  depends_on          = [google_service_networking_connection.psa]

  settings {
    tier              = "db-f1-micro" # smallest; use a dedicated-core tier for prod load tests
    availability_type = var.env == "prod" ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 20
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = var.env == "prod"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_database" "cell" {
  project  = var.project_id
  name     = "cell"
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "admin" {
  project  = var.project_id
  name     = "cell_admin"
  instance = google_sql_database_instance.this.name
  password = random_password.admin.result
}

output "database" {
  value = {
    host       = google_sql_database_instance.this.private_ip_address
    port       = 5432
    secret_ref = google_secret_manager_secret.db.id
  }
}
