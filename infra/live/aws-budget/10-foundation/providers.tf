provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "cloudbridge"
    }
  }
}

# The cell facade wires the GCP implementations too (with count = 0 here), so Terraform still
# configures the google provider in this stack. It never makes a call; a placeholder token stops
# it from searching for credentials an AWS stack doesn't have. (Leaky abstraction: one facade,
# two providers per stack.)
provider "google" {
  project      = "unused-in-an-aws-cell"
  access_token = "unused-in-an-aws-cell"
}
