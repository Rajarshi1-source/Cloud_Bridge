provider "aws" {
  region = "ap-south-1"
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster.endpoint
    cluster_ca_certificate = local.cluster.ca_certificate
    exec = {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster.name, "--region", "ap-south-1"]
    }
  }
}
