resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = substr("${var.name}-nodes", 0, 30)
  display_name = "CloudBridge GKE nodes (least privilege)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_compute_global_address" "ingress" {
  project = var.project_id
  name    = "${var.name}-ingress"
}

resource "google_container_cluster" "this" {
  project             = var.project_id
  name                = var.name
  location            = var.zone
  network             = var.network
  subnetwork          = var.subnetwork
  min_master_version  = var.k8s_version
  deletion_protection = var.env == "prod"

  release_channel {
    channel = "REGULAR"
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-01T20:30:00Z"
      end_time   = "2026-01-01T23:30:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  datapath_provider        = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.admin_cidrs
      content {
        cidr_block = cidr_blocks.value
      }
    }
  }

  resource_labels = var.labels
}

resource "google_container_node_pool" "default" {
  project            = var.project_id
  name               = "default"
  location           = var.zone
  cluster            = google_container_cluster.this.name
  initial_node_count = var.desired

  autoscaling {
    min_node_count = 1
    max_node_count = var.max
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}
