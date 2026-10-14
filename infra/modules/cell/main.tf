locals {
  name = "cb-${var.cloud}-${var.env}"
  labels = {
    "cb-cell"    = local.name
    "cb-cloud"   = var.cloud
    "cb-env"     = var.env
    "managed-by" = "terraform"
  }
  managed = var.profile == "managed"
}

# ---------- network ----------
module "network_aws" {
  source = "../network/aws"
  count  = var.cloud == "aws" ? 1 : 0
  name   = local.name
  cidr   = "10.20.0.0/16"
  nat    = local.managed
  tags   = local.labels
}

module "network_gcp" {
  source     = "../network/gcp"
  count      = var.cloud == "gcp" ? 1 : 0
  name       = local.name
  project_id = var.gcp_project_id
  region     = var.region
  cidr       = "10.30.0.0/20"
  nat        = local.managed
}

locals {
  net = one(concat(module.network_aws, module.network_gcp))
}

# ---------- cluster ----------
module "eks" {
  source        = "../cluster/aws-eks"
  count         = var.cloud == "aws" && local.managed ? 1 : 0
  name          = local.name
  k8s_version   = var.kubernetes_minor
  vpc_id        = local.net.network_id
  subnet_ids    = local.net.private_subnet_ids
  instance_type = local.instance_type
  desired       = var.node_count
  max           = var.node_max
  admin_cidrs   = var.admin_cidrs
  ci_role_arn   = var.ci_role_arn
  tags          = local.labels
}

module "gke" {
  source       = "../cluster/gcp-gke"
  count        = var.cloud == "gcp" && local.managed ? 1 : 0
  name         = local.name
  env          = var.env
  project_id   = var.gcp_project_id
  zone         = "${var.region}-a"
  k8s_version  = var.kubernetes_minor
  network      = local.net.network_id
  subnetwork   = local.net.private_subnet_ids[0]
  machine_type = local.instance_type
  desired      = var.node_count
  max          = var.node_max
  admin_cidrs  = var.admin_cidrs
  labels       = local.labels
}

module "k3s_aws" {
  source        = "../cluster/k3s-vm-aws"
  count         = var.cloud == "aws" && !local.managed ? 1 : 0
  name          = local.name
  vpc_id        = local.net.network_id
  subnet_id     = local.net.public_subnet_ids[0]
  instance_type = local.instance_type
  k8s_version   = var.kubernetes_minor
  origin_cidrs  = var.cloudflare_ipv4
  tags          = local.labels
}

module "k3s_gcp" {
  source       = "../cluster/k3s-vm-gcp"
  count        = var.cloud == "gcp" && !local.managed ? 1 : 0
  name         = local.name
  project_id   = var.gcp_project_id
  zone         = "${var.region}-a"
  network      = local.net.network_id
  subnetwork   = local.net.public_subnet_ids[0]
  machine_type = local.instance_type
  k8s_version  = var.kubernetes_minor
  origin_cidrs = var.cloudflare_ipv4
  labels       = local.labels
}

locals {
  cluster = one(concat(
    module.eks[*].cluster, module.gke[*].cluster,
    module.k3s_aws[*].cluster, module.k3s_gcp[*].cluster,
  ))
}

# ---------- data (managed profile only; budget runs them in-cluster) ----------
module "db_aws" {
  source         = "../database/aws-rds"
  count          = var.cloud == "aws" && local.managed ? 1 : 0
  name           = local.name
  env            = var.env
  vpc_id         = local.net.network_id
  subnet_ids     = local.net.private_subnet_ids
  allowed_sg     = local.cluster.node_security_group
  engine_version = "18"
  tags           = local.labels
}

module "db_gcp" {
  source           = "../database/gcp-cloudsql"
  count            = var.cloud == "gcp" && local.managed ? 1 : 0
  name             = local.name
  env              = var.env
  project_id       = var.gcp_project_id
  region           = var.region
  network          = local.net.network_id
  database_version = "POSTGRES_18"
  labels           = local.labels
}

module "cache_aws" {
  source         = "../cache/aws-elasticache"
  count          = var.cloud == "aws" && local.managed && var.managed_cache ? 1 : 0
  name           = local.name
  vpc_id         = local.net.network_id
  subnet_ids     = local.net.private_subnet_ids
  allowed_sg     = local.cluster.node_security_group
  engine_version = "9.0"
  tags           = local.labels
}

module "cache_gcp" {
  source         = "../cache/gcp-memorystore"
  count          = var.cloud == "gcp" && local.managed && var.managed_cache ? 1 : 0
  name           = local.name
  project_id     = var.gcp_project_id
  region         = var.region
  network        = local.net.network_id
  engine_version = "VALKEY_9_0"
  labels         = local.labels
}

locals {
  database = one(concat(module.db_aws[*].database, module.db_gcp[*].database))
  cache    = one(concat(module.cache_aws[*].cache, module.cache_gcp[*].cache))
}
