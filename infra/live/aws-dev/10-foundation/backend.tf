terraform {
  backend "s3" {
    bucket       = "cb-tfstate-aws"
    key          = "aws-dev/10-foundation.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
