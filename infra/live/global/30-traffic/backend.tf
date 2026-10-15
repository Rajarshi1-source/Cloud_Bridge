terraform {
  # GCS, not S3: AWS is the larger cell and so the likelier evacuation source; this stack must stay
  # applyable while AWS is the cloud that is failing. If GCS is unreachable too: tools/cf_break_glass.py (Week 7).
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "global/traffic"
  }
}
