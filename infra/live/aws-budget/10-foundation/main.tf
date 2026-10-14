# Cloudflare publishes its origin ranges at a public URL; reading them needs no Cloudflare token,
# so a cell stack never holds Cloudflare credentials. Origins accept 443 only from these ranges.
data "http" "cloudflare_ipv4" {
  url = "https://www.cloudflare.com/ips-v4"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && length(trimspace(self.response_body)) > 0
      error_message = "Could not read Cloudflare's IPv4 ranges; refusing to build an origin firewall without them."
    }
  }
}

locals {
  cloudflare_ipv4 = compact(split("\n", trimspace(data.http.cloudflare_ipv4.response_body)))
}

module "cell" {
  source          = "../../../modules/cell"
  cloud           = var.cloud
  profile         = var.profile
  env             = var.env
  region          = var.region
  shape           = var.shape
  gcp_project_id  = var.gcp_project_id
  cloudflare_ipv4 = local.cloudflare_ipv4
}
