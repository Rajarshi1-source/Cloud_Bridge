terraform {
  backend "s3" {
    bucket       = "cb-tfstate-aws"
    key          = "aws-budget/10-foundation.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # native S3 lock file; DynamoDB locking is deprecated
  }
}
