provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "cloudbridge"
    }
  }
}

# The cell facade wires the GCP implementations too (count = 0 here); a placeholder token stops the
# google provider from looking for credentials an AWS stack doesn't have.
provider "google" {
  project      = "unused-in-an-aws-cell"
  access_token = "unused-in-an-aws-cell"
}
