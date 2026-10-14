provider "google" {
  project = var.gcp_project_id
  region  = var.region
}

# The cell facade wires the AWS implementations too (with count = 0 here), so Terraform still
# configures the aws provider in this stack. It never makes a call; these settings stop it from
# validating credentials or calling STS/IMDS. (Leaky abstraction: one facade, two providers per stack.)
provider "aws" {
  region                      = "ap-south-1"
  access_key                  = "unused-in-a-gcp-cell"
  secret_key                  = "unused-in-a-gcp-cell"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}
