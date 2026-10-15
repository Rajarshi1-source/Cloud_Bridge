terraform {
  required_version = ">= 1.15.0, < 2.0.0"
  required_providers {
    # v5 is generated from Cloudflare's API schema and ships every 2–3 weeks: pin the minor, and run
    # `terraform validate` + the stack test on every bump (nested attribute names do move).
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28.0"
    }
  }
}
