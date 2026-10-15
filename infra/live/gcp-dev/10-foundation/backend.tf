terraform {
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "gcp-dev/10-foundation"
  }
}
