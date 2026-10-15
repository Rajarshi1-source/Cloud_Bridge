terraform {
  # This state holds the origin private key: the bucket is CMEK/Google-encrypted, versioned and
  # readable only by the apply identity. Applied rarely (the certificate is valid for 15 years).
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "global/origin-tls"
  }
}
