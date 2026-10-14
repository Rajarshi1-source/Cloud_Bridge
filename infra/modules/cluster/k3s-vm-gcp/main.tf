variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "origin_cidrs" {
  type = list(string)
}

variable "labels" {
  type = map(string)
}

resource "google_service_account" "vm" {
  project      = var.project_id
  account_id   = substr("${var.name}-vm", 0, 30)
  display_name = "CloudBridge budget VM"
}

resource "google_compute_address" "vm" {
  project = var.project_id
  name    = "${var.name}-vm"
  region  = join("-", slice(split("-", var.zone), 0, 2))
}

resource "google_compute_firewall" "https_from_cloudflare" {
  project       = var.project_id
  name          = "${var.name}-https-cf"
  network       = var.network
  source_ranges = var.origin_cidrs
  target_tags   = ["cb-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "iap_ssh" {
  project       = var.project_id
  name          = "${var.name}-iap-ssh"
  network       = var.network
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding range — Ansible connects through IAP
  target_tags   = ["cb-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_instance" "vm" {
  project      = var.project_id
  name         = var.name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["cb-k3s"]
  labels       = merge(var.labels, { "cb-ansible-role" = "k3s_server", "cb-k8s-minor" = replace(var.k8s_version, ".", "-") })

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnetwork
    access_config {
      nat_ip = google_compute_address.vm.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }
}

output "cluster" {
  value = {
    name                = var.name
    endpoint            = "https://127.0.0.1:6443"
    ca_certificate      = ""
    k8s_version         = var.k8s_version
    origin              = google_compute_address.vm.address
    node_security_group = null
    auth                = { kind = "k3s-iap", instance = var.name, zone = var.zone }
  }
}
