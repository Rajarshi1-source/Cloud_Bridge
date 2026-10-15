# One Cloudflare Origin CA certificate for every origin (Full strict TLS), stored in each cloud's
# secret manager. Ansible origin_tls (budget) or External Secrets (managed) reads its own cloud's
# copy, so a cell never depends on the other cloud to serve TLS.

variable "gcp_project_id" {
  type = string
}

locals {
  domain    = yamldecode(file("${path.module}/../../../../gitops/global/values.yaml")).domain
  hostnames = [local.domain, "*.${local.domain}"] # app., admin-aws., admin-gcp., cp.
  pair = jsonencode({
    certificate = cloudflare_origin_ca_certificate.origin.certificate
    private_key = tls_private_key.origin.private_key_pem
  })
}

resource "tls_private_key" "origin" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem
  dns_names       = local.hostnames
  subject {
    common_name  = local.domain
    organization = "CloudBridge"
  }
}

resource "cloudflare_origin_ca_certificate" "origin" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = local.hostnames
  request_type       = "origin-ecc"
  requested_validity = 5475
}

resource "aws_secretsmanager_secret" "origin_tls" {
  name                    = "cb/origin-tls"
  description             = "Cloudflare Origin CA certificate + key for CloudBridge origins"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "origin_tls" {
  secret_id     = aws_secretsmanager_secret.origin_tls.id
  secret_string = local.pair
}

resource "google_secret_manager_secret" "origin_tls" {
  secret_id = "cb-origin-tls"
  labels    = { project = "cloudbridge" }
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "origin_tls" {
  secret      = google_secret_manager_secret.origin_tls.id
  secret_data = local.pair
}

output "certificate_expires_on" {
  value = cloudflare_origin_ca_certificate.origin.expires_on
}

output "hostnames" {
  value = local.hostnames
}
