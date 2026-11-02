terraform {
  backend "s3" {
    bucket       = "cb-tfstate-aws"
    key          = "aws-dev/20-bootstrap.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
