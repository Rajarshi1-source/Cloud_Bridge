# Offline: Cloudflare and both clouds are mocked; the key and CSR are generated for real (tls).
mock_provider "cloudflare" {
  mock_resource "cloudflare_origin_ca_certificate" {
    defaults = {
      certificate = "-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\n"
    }
  }
}

mock_provider "aws" {}

mock_provider "google" {}

run "one_certificate_in_both_secret_managers" {
  command = apply

  assert {
    condition     = length(output.hostnames) == 2 && anytrue([for h in output.hostnames : startswith(h, "*.")])
    error_message = "The certificate must cover every per-cell host (wildcard)."
  }
  assert {
    condition     = aws_secretsmanager_secret.origin_tls.name == "cb/origin-tls" && google_secret_manager_secret.origin_tls.secret_id == "cb-origin-tls"
    error_message = "Secret names must match what ansible/roles/origin_tls reads."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.origin_tls.secret_string).private_key == tls_private_key.origin.private_key_pem
    error_message = "The AWS copy must hold the key that signed the CSR."
  }
  assert {
    condition     = google_secret_manager_secret_version.origin_tls.secret_data == aws_secretsmanager_secret_version.origin_tls.secret_string
    error_message = "Both clouds must hold the same certificate and key."
  }
}
