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
