variable "name" {
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

variable "engine_version" {
  type = string
}

variable "labels" {
  type = map(string)
}

resource "google_memorystore_instance" "this" {
  project                     = var.project_id
  instance_id                 = var.name
  location                    = var.region
  engine_version              = var.engine_version
  mode                        = "CLUSTER_DISABLED"
  shard_count                 = 1
  replica_count               = 0
  node_type                   = "SHARED_CORE_NANO"
  transit_encryption_mode     = "SERVER_AUTHENTICATION"
  deletion_protection_enabled = true
  labels                      = var.labels

  desired_auto_created_endpoints {
    network    = var.network
    project_id = var.project_id
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "cache" {
  value = {
    # endpoints is empty until the PSC connection exists (OpenTofu plans it as a known empty list), and its
    # nested path varies by provider version — read it from `terraform console` after the first apply.
    host = try(google_memorystore_instance.this.endpoints[0].connections[0].psc_auto_connection[0].ip_address, null)
    port = 6379
    tls  = true
  }
}
