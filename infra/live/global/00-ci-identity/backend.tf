terraform {
  # Bootstrapped once by a human with their own credentials; CI can't create its own trust.
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "global/ci-identity"
  }
}
