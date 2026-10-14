terraform {
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "gcp-budget/10-foundation" # GCS backend locks natively
  }
}
