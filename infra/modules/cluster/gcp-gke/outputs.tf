output "cluster" {
  value = {
    name                = google_container_cluster.this.name
    endpoint            = "https://${google_container_cluster.this.endpoint}"
    ca_certificate      = try(base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate), null) # block is empty until GKE fills it
    k8s_version         = google_container_cluster.this.master_version
    origin              = google_compute_global_address.ingress.address # known up front (leaky #2)
    node_security_group = null                                          # GCP uses firewall rules on the network
    auth                = { kind = "gcp-gke", cluster_name = google_container_cluster.this.name, location = var.zone, project = var.project_id }
  }
}
