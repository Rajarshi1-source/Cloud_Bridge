provider "cloudflare" {
  # CLOUDFLARE_API_TOKEN with Zone: SSL and Certificates Edit on the CloudBridge zone.
}

provider "aws" {
  region = "ap-south-1"
  default_tags {
    tags = {
      project = "cloudbridge"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
}
