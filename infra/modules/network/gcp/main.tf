variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "cidr" {
  type = string
}

variable "nat" {
  type = bool
}

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  project                  = var.project_id
  name                     = "${var.name}-main"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.cidr
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.40.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.41.0.0/20"
  }
}

resource "google_compute_router" "this" {
  count   = var.nat ? 1 : 0
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count                              = var.nat ? 1 : 0
  project                            = var.project_id
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

output "network_id" {
  value = google_compute_network.this.id
}

# GCP subnets are regional and not "public"/"private" — exposure is per VM. Both lists point at
# the same subnet so the facade can use one interface (leaky abstraction, documented).
output "public_subnet_ids" {
  value = [google_compute_subnetwork.this.id]
}

output "private_subnet_ids" {
  value = [google_compute_subnetwork.this.id]
}
