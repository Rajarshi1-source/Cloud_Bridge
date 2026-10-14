# CloudBridge Terraform Cells — Starter Code

Complete starter files for the cell layer. Every block follows the "one argument per single-line block" rule. Nested attribute names for fast-moving resources (Memorystore for Valkey, ElastiCache Valkey) are marked **verify** — check them against the provider version in your lock file before the first apply.

## Contents
1. Shared versions + Makefile
2. `modules/cell` (facade): variables, shapes, main, outputs
3. Contract test
4. Network implementations (AWS, GCP)
5. Cluster implementations (EKS, GKE, k3s VM on AWS, k3s VM on GCP)
6. Data services (RDS, Cloud SQL, ElastiCache Valkey, Memorystore Valkey)
7. A live stack (`live/aws-prod/10-foundation`, `live/gcp-prod/10-foundation`)
8. Budget-profile bootstrap note

---

## 1. Shared versions + Makefile

```hcl
# infra/live/_shared/versions.tf  (symlink into each stack)
terraform {
  required_version = ">= 1.15.0, < 2.0.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    google = { source = "hashicorp/google", version = "~> 7.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
```

```makefile
# infra/Makefile
CLOUD ?= aws
ENV   ?= dev
STACK  = live/$(CLOUD)-$(ENV)

fmt:            ; terraform fmt -recursive -check
test:           ; cd modules/cell && terraform init -backend=false && terraform test
test-tofu:      ; cd modules/cell && tofu init -backend=false && tofu test
plan:           ; cd $(STACK)/10-foundation && terraform init -input=false && terraform plan -out=tfplan
apply:          ; cd $(STACK)/10-foundation && terraform apply tfplan

new-cell:
	@test ! -d $(STACK) || (echo "$(STACK) exists" && exit 1)
	cp -r live/_template $(STACK)
	sed -i 's/__CLOUD__/$(CLOUD)/; s/__ENV__/$(ENV)/' $(STACK)/10-foundation/terraform.tfvars $(STACK)/*/backend.tf
	@echo "Created $(STACK). Review backend.tf, then: make plan CLOUD=$(CLOUD) ENV=$(ENV)"

budget-up:
	$(MAKE) plan apply CLOUD=aws ENV=budget && $(MAKE) plan apply CLOUD=gcp ENV=budget
	cd ../ansible && ansible-playbook -i inventories/ playbooks/site.yml
```

---

## 2. `modules/cell` — the facade

```hcl
# infra/modules/cell/variables.tf
variable "cloud" {
  type        = string
  description = "Target cloud for this cell."
  validation {
    condition     = contains(["aws", "gcp"], var.cloud)
    error_message = "cloud must be \"aws\" or \"gcp\"."
  }
}

variable "profile" {
  type    = string
  default = "managed"
  validation {
    condition     = contains(["managed", "budget"], var.profile)
    error_message = "profile must be \"managed\" or \"budget\"."
  }
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "shape" {
  type    = string
  default = "small"
}

variable "kubernetes_minor" {
  type    = string
  default = "1.36"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "node_max" {
  type        = number
  default     = 5
  description = "Sized so this cell can absorb 100% of traffic during an evacuation."
}

variable "gcp_project_id" {
  type    = string
  default = null
}

variable "admin_cidrs" {
  type    = list(string)
  default = []
}

variable "cloudflare_ipv4" {
  type        = list(string)
  description = "Cloudflare origin ranges (data.cloudflare_ip_ranges.cf.ipv4_cidrs passed in by the stack)."
}

variable "managed_cache" {
  type    = bool
  default = true
}

variable "ci_role_arn" {
  type        = string
  default     = null
  description = "AWS only: CI role granted an EKS access entry."
}
```

```hcl
# infra/modules/cell/shapes.tf
locals {
  shapes = {
    small    = { aws = "t3.medium", gcp = "e2-medium", vcpu = 2, mem_gib = 4, class = "burstable" }
    standard = { aws = "m6i.large", gcp = "n2-standard-2", vcpu = 2, mem_gib = 8, class = "general-purpose" }
    large    = { aws = "m6i.xlarge", gcp = "n2-standard-4", vcpu = 4, mem_gib = 16, class = "general-purpose" }
  }
  budget_shapes = {
    small = { aws = "t3.small", gcp = "e2-small", vcpu = 2, mem_gib = 2, class = "burstable" }
  }
  shape_row     = var.profile == "budget" ? local.budget_shapes[var.shape] : local.shapes[var.shape]
  instance_type = local.shape_row[var.cloud]
}
```

```hcl
# infra/modules/cell/main.tf
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
```

```hcl
# infra/modules/cell/outputs.tf — THE INTERFACE
output "cell" {
  value = {
    name    = local.name
    cloud   = var.cloud
    profile = var.profile
    region  = var.region
    shape   = local.shape_row
    origin  = local.cluster.origin
  }
}

output "cluster" {
  value     = local.cluster
  sensitive = true
}

output "database" {
  value     = local.database
  sensitive = true
}

output "cache" {
  value     = local.cache
  sensitive = true
}
```

---

## 3. Contract test

```hcl
# infra/modules/cell/tests/contract.tftest.hcl
# Mock providers generate values for computed attributes, so `apply` runs offline.
# Attributes that this repo indexes ([0]) or decodes (base64) need explicit defaults —
# otherwise a generated empty list or random string breaks the expression.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
    }
  }
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
  # The provider validates assume_role_policy as JSON even under mocks; a generated random string fails.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  # Attributes other resources validate as ARNs need ARN-shaped mock values.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/cb-mock"
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      # Only computed attributes: vpc_config is a configured block, so its mock can't be overridden here.
      certificate_authority = [{ data = "Y2E=" }]
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:111122223333:secret:db", kms_key_id = "", secret_status = "active" }]
    }
  }
}

mock_provider "google" {
  # Cloud SQL validates private_network as a network self-link, so the mocked id must look like one.
  mock_resource "google_compute_network" {
    defaults = {
      id = "projects/cb-test/global/networks/cb-gcp-test"
    }
  }
  mock_resource "google_container_cluster" {
    defaults = {
      master_auth = [{ cluster_ca_certificate = "Y2E=", client_certificate = "", client_key = "", client_certificate_config = [] }]
    }
  }
  mock_resource "google_memorystore_instance" {
    defaults = {
      endpoints = [{ connections = [{ psc_auto_connection = [{ ip_address = "10.0.0.5" }] }] }]
    }
  }
}

mock_provider "random" {}

variables {
  env             = "test"
  region          = "ap-south-1"
  cloudflare_ipv4 = ["173.245.48.0/20"]
  gcp_project_id  = "cb-test"
}

run "aws_managed_contract" {
  # plan, not apply: managed data services carry prevent_destroy, so a test apply could never tear down.
  command = plan
  variables {
    cloud   = "aws"
    profile = "managed"
  }
  assert {
    condition     = alltrue([for k in ["name", "endpoint", "ca_certificate", "k8s_version", "origin", "node_security_group", "auth"] : contains(keys(output.cluster), k)])
    error_message = "AWS managed cluster contract keys missing."
  }
  assert {
    condition     = output.database != null
    error_message = "Managed profile must provide a managed database."
  }
}

run "gcp_managed_contract" {
  # plan, not apply: managed data services carry prevent_destroy, so a test apply could never tear down.
  command = plan
  variables {
    cloud   = "gcp"
    profile = "managed"
    region  = "asia-south1"
  }
  assert {
    condition     = alltrue([for k in ["name", "endpoint", "ca_certificate", "k8s_version", "origin", "node_security_group", "auth"] : contains(keys(output.cluster), k)])
    error_message = "GCP managed cluster contract keys missing."
  }
}

run "aws_budget_contract" {
  command = apply
  variables {
    cloud   = "aws"
    profile = "budget"
  }
  assert {
    condition     = output.database == null && output.cache == null
    error_message = "Budget profile must leave data services to the cluster."
  }
  assert {
    condition     = output.cell.shape.mem_gib == 2
    error_message = "Budget shape must be the 2 GiB pair."
  }
}

run "gcp_budget_contract" {
  command = apply
  variables {
    cloud   = "gcp"
    profile = "budget"
    region  = "asia-south1"
  }
  assert {
    condition     = output.cell.cloud == "gcp" && contains(keys(output.cluster), "origin")
    error_message = "GCP budget contract broken."
  }
}

run "shape_parity_standard" {
  command = plan
  variables {
    cloud  = "gcp"
    region = "asia-south1"
    shape  = "standard"
  }
  assert {
    condition     = output.cell.shape.vcpu == 2 && output.cell.shape.mem_gib == 8
    error_message = "standard must be 2 vCPU / 8 GiB on every cloud."
  }
}

run "rejects_unknown_cloud" {
  command = plan
  variables {
    cloud = "azure"
  }
  expect_failures = [var.cloud]
}
```

---

## 4. Network implementations

```hcl
# infra/modules/network/aws/main.tf
variable "name" {
  type = string
}

variable "cidr" {
  type = string
}

variable "nat" {
  type = bool
}

variable "tags" {
  type = map(string)
}

data "aws_availability_zones" "this" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.this.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = var.tags
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.name}-public-${count.index}", "kubernetes.io/role/elb" = "1" })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 4, count.index + 8)
  availability_zone = local.azs[count.index]
  tags              = merge(var.tags, { Name = "${var.name}-private-${count.index}", "kubernetes.io/role/internal-elb" = "1" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = var.tags
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = var.nat ? 1 : 0
  domain = "vpc"
  tags   = var.tags
}

resource "aws_nat_gateway" "this" {
  count         = var.nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = var.tags
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = var.tags
}

resource "aws_route" "private_nat" {
  count                  = var.nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

output "network_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
```
Single NAT gateway is a deliberate cost choice for a portfolio project — note it in the leaky-abstraction/cost docs (one AZ's NAT is a SPOF for private egress).

```hcl
# infra/modules/network/gcp/main.tf
variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "cidr" {
  type = string
}

variable "nat" {
  type = bool
}

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  project                  = var.project_id
  name                     = "${var.name}-main"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.cidr
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.40.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.41.0.0/20"
  }
}

resource "google_compute_router" "this" {
  count   = var.nat ? 1 : 0
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count                              = var.nat ? 1 : 0
  project                            = var.project_id
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

output "network_id" {
  value = google_compute_network.this.id
}

# GCP subnets are regional and not "public"/"private" — exposure is per VM. Both lists point at
# the same subnet so the facade can use one interface (leaky abstraction, documented).
output "public_subnet_ids" {
  value = [google_compute_subnetwork.this.id]
}

output "private_subnet_ids" {
  value = [google_compute_subnetwork.this.id]
}
```

---

## 5. Cluster implementations

### 5.1 EKS

```hcl
# infra/modules/cluster/aws-eks/variables.tf
variable "name" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  type = string
}

variable "desired" {
  type = number
}

variable "max" {
  type = number
}

variable "admin_cidrs" {
  type = list(string)
}

variable "ci_role_arn" {
  type    = string
  default = null
}

variable "tags" {
  type = map(string)
}
```

```hcl
# infra/modules/cluster/aws-eks/main.tf
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.k8s_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.desired
    min_size     = 1
    max_size     = var.max
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name         = aws_eks_cluster.this.name
  addon_name           = "vpc-cni"
  configuration_values = jsonencode({ enableNetworkPolicy = "true" }) # NetworkPolicy enforcement (leaky #5)
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_eks_access_entry" "ci" {
  count         = var.ci_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ci_role_arn
}

resource "aws_eks_access_policy_association" "ci_admin" {
  count         = var.ci_role_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}
```

```hcl
# infra/modules/cluster/aws-eks/outputs.tf
output "cluster" {
  value = {
    name                = aws_eks_cluster.this.name
    endpoint            = aws_eks_cluster.this.endpoint
    ca_certificate      = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    k8s_version         = aws_eks_cluster.this.version
    origin              = null # ALB hostname appears after the controller runs → 20-bootstrap output
    node_security_group = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
    auth                = { kind = "aws-eks", cluster_name = aws_eks_cluster.this.name }
  }
}
```

### 5.2 GKE

```hcl
# infra/modules/cluster/gcp-gke/variables.tf
variable "name" {
  type = string
}

variable "env" {
  type = string
}

variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "desired" {
  type = number
}

variable "max" {
  type = number
}

variable "admin_cidrs" {
  type = list(string)
}

variable "labels" {
  type = map(string)
}
```

```hcl
# infra/modules/cluster/gcp-gke/main.tf
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = substr("${var.name}-nodes", 0, 30)
  display_name = "CloudBridge GKE nodes (least privilege)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_compute_global_address" "ingress" {
  project = var.project_id
  name    = "${var.name}-ingress"
}

resource "google_container_cluster" "this" {
  project             = var.project_id
  name                = var.name
  location            = var.zone
  network             = var.network
  subnetwork          = var.subnetwork
  min_master_version  = var.k8s_version
  deletion_protection = var.env == "prod"

  release_channel {
    channel = "REGULAR"
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-01T20:30:00Z"
      end_time   = "2026-01-01T23:30:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  datapath_provider        = "ADVANCED_DATAPATH"

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.admin_cidrs
      content {
        cidr_block = cidr_blocks.value
      }
    }
  }

  resource_labels = var.labels
}

resource "google_container_node_pool" "default" {
  project            = var.project_id
  name               = "default"
  location           = var.zone
  cluster            = google_container_cluster.this.name
  initial_node_count = var.desired

  autoscaling {
    min_node_count = 1
    max_node_count = var.max
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}
```

```hcl
# infra/modules/cluster/gcp-gke/outputs.tf
output "cluster" {
  value = {
    name                = google_container_cluster.this.name
    endpoint            = "https://${google_container_cluster.this.endpoint}"
    ca_certificate      = try(base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate), null) # block is empty until GKE fills it
    k8s_version         = google_container_cluster.this.master_version
    origin              = google_compute_global_address.ingress.address # known up front (leaky #2)
    node_security_group = null                                          # GCP uses firewall rules on the network
    auth                = { kind = "gcp-gke", cluster_name = google_container_cluster.this.name, location = var.zone }
  }
}
```

### 5.3 k3s VM on AWS (budget)

```hcl
# infra/modules/cluster/k3s-vm-aws/main.tf
variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "origin_cidrs" {
  type = list(string)
}

variable "tags" {
  type = map(string)
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vm" {
  name               = "${var.name}-vm"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Ansible connects via SSM, no SSH
}

# Ansible's aws_ssm connection plugin moves files through S3, so the VM (and the CI role that runs
# Ansible) need a transfer bucket. Short-lived objects only; never a place for state or secrets.
resource "aws_s3_bucket" "ssm_transfer" {
  bucket_prefix = "${var.name}-ssm-"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  rule {
    id     = "expire-transfers"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

data "aws_iam_policy_document" "ssm_transfer" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
  statement {
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.ssm_transfer.arn]
  }
}

resource "aws_iam_role_policy" "ssm_transfer" {
  name   = "ssm-transfer"
  role   = aws_iam_role.vm.id
  policy = data.aws_iam_policy_document.ssm_transfer.json
}

resource "aws_iam_instance_profile" "vm" {
  name = "${var.name}-vm"
  role = aws_iam_role.vm.name
}

resource "aws_security_group" "vm" {
  name   = "${var.name}-vm"
  vpc_id = var.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "https_from_cloudflare" {
  for_each          = toset(var.origin_cidrs)
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "vm" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.vm.id]
  iam_instance_profile   = aws_iam_instance_profile.vm.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = var.name, "cb-ansible-role" = "k3s_server", "cb-k8s-minor" = var.k8s_version })

  lifecycle {
    ignore_changes = [ami] # OS upgrades = planned rebuild, not drift
  }
}

resource "aws_eip" "vm" {
  domain   = "vpc"
  instance = aws_instance.vm.id
  tags     = var.tags
}

output "cluster" {
  value = {
    name                = var.name
    endpoint            = "https://127.0.0.1:6443" # API never exposed; reached via SSM port-forward
    ca_certificate      = ""
    k8s_version         = var.k8s_version
    origin              = aws_eip.vm.public_ip
    node_security_group = aws_security_group.vm.id
    auth                = { kind = "k3s-ssm", instance_id = aws_instance.vm.id, transfer_bucket = aws_s3_bucket.ssm_transfer.bucket }
  }
}
```

### 5.4 k3s VM on GCP (budget)

```hcl
# infra/modules/cluster/k3s-vm-gcp/main.tf
variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "origin_cidrs" {
  type = list(string)
}

variable "labels" {
  type = map(string)
}

resource "google_service_account" "vm" {
  project      = var.project_id
  account_id   = substr("${var.name}-vm", 0, 30)
  display_name = "CloudBridge budget VM"
}

resource "google_compute_address" "vm" {
  project = var.project_id
  name    = "${var.name}-vm"
  region  = join("-", slice(split("-", var.zone), 0, 2))
}

resource "google_compute_firewall" "https_from_cloudflare" {
  project       = var.project_id
  name          = "${var.name}-https-cf"
  network       = var.network
  source_ranges = var.origin_cidrs
  target_tags   = ["cb-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "iap_ssh" {
  project       = var.project_id
  name          = "${var.name}-iap-ssh"
  network       = var.network
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding range — Ansible connects through IAP
  target_tags   = ["cb-k3s"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_instance" "vm" {
  project      = var.project_id
  name         = var.name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["cb-k3s"]
  labels       = merge(var.labels, { "cb-ansible-role" = "k3s_server", "cb-k8s-minor" = replace(var.k8s_version, ".", "-") })

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnetwork
    access_config {
      nat_ip = google_compute_address.vm.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }
}

output "cluster" {
  value = {
    name                = var.name
    endpoint            = "https://127.0.0.1:6443"
    ca_certificate      = ""
    k8s_version         = var.k8s_version
    origin              = google_compute_address.vm.address
    node_security_group = null
    auth                = { kind = "k3s-iap", instance = var.name, zone = var.zone }
  }
}
```
Note the label value `1-36`: GCP labels can't contain dots (leaky #9).

---

## 6. Data services

```hcl
# infra/modules/database/aws-rds/main.tf
variable "name" {
  type = string
}

variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_sg" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "tags" {
  type = map(string)
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name   = "${var.name}-db"
  vpc_id = var.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "pg" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.allowed_sg
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_instance" "this" {
  identifier                  = var.name
  engine                      = "postgres"
  engine_version              = var.engine_version
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "cell"
  username                    = "cell_admin"
  manage_master_user_password = true # password generated and stored in Secrets Manager by RDS
  multi_az                    = var.env == "prod"
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  backup_retention_period     = 7
  deletion_protection         = var.env == "prod"
  skip_final_snapshot         = var.env != "prod"
  final_snapshot_identifier   = "${var.name}-final"
  auto_minor_version_upgrade  = true
  tags                        = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

output "database" {
  value = {
    host       = aws_db_instance.this.address
    port       = aws_db_instance.this.port
    secret_ref = aws_db_instance.this.master_user_secret[0].secret_arn
  }
}
```

```hcl
# infra/modules/database/gcp-cloudsql/main.tf
variable "name" {
  type = string
}

variable "env" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network" {
  type = string
}

variable "database_version" {
  type = string
}

variable "labels" {
  type = map(string)
}

resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${var.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = var.network
}

resource "google_service_networking_connection" "psa" {
  network                 = var.network
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

resource "random_password" "admin" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "db" {
  project   = var.project_id
  secret_id = "${var.name}-db-admin"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db" {
  secret      = google_secret_manager_secret.db.id
  secret_data = random_password.admin.result
}

resource "google_sql_database_instance" "this" {
  project             = var.project_id
  name                = var.name
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.env == "prod"
  depends_on          = [google_service_networking_connection.psa]

  settings {
    tier              = "db-f1-micro" # smallest; use a dedicated-core tier for prod load tests
    availability_type = var.env == "prod" ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 20
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = var.env == "prod"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_database" "cell" {
  project  = var.project_id
  name     = "cell"
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "admin" {
  project  = var.project_id
  name     = "cell_admin"
  instance = google_sql_database_instance.this.name
  password = random_password.admin.result
}

output "database" {
  value = {
    host       = google_sql_database_instance.this.private_ip_address
    port       = 5432
    secret_ref = google_secret_manager_secret.db.id
  }
}
```
(The password still lands in Terraform state via `random_password` — encrypted bucket + restricted access is the mitigation; RDS's `manage_master_user_password` avoids it on AWS. Leaky abstraction, documented.)

```hcl
# infra/modules/cache/aws-elasticache/main.tf   (verify Valkey 9.0 engine_version string)
variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_sg" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "tags" {
  type = map(string)
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "cache" {
  name   = "${var.name}-cache"
  vpc_id = var.vpc_id
  tags   = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "valkey" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = var.allowed_sg
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = var.name
  description                = "CloudBridge cell cache"
  engine                     = "valkey"
  engine_version             = var.engine_version
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.cache.id]
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  tags                       = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

output "cache" {
  value = {
    host = aws_elasticache_replication_group.this.primary_endpoint_address
    port = 6379
    tls  = true
  }
}
```

```hcl
# infra/modules/cache/gcp-memorystore/main.tf   (verify argument names for google ~> 7.0)
variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network" {
  type = string
}

variable "engine_version" {
  type = string
}

variable "labels" {
  type = map(string)
}

resource "google_memorystore_instance" "this" {
  project                     = var.project_id
  instance_id                 = var.name
  location                    = var.region
  engine_version              = var.engine_version
  mode                        = "CLUSTER_DISABLED"
  shard_count                 = 1
  replica_count               = 0
  node_type                   = "SHARED_CORE_NANO"
  transit_encryption_mode     = "SERVER_AUTHENTICATION"
  deletion_protection_enabled = true
  labels                      = var.labels

  desired_auto_created_endpoints {
    network    = var.network
    project_id = var.project_id
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "cache" {
  value = {
    host = google_memorystore_instance.this.endpoints[0].connections[0].psc_auto_connection[0].ip_address
    port = 6379
    tls  = true
  }
}
```
Memorystore for Valkey uses Private Service Connect; it also needs a `google_network_connectivity_service_connection_policy` for the network. The endpoint attribute path above is the part most likely to differ by provider version — read it from `terraform console` after the first apply rather than trusting this line.

---

## 7. Live stacks

```hcl
# infra/live/aws-prod/10-foundation/main.tf
provider "aws" {
  region = "ap-south-1"
  default_tags {
    tags = { project = "cloudbridge" }
  }
}

# Prefer the http-provider pattern in 7b; this provider needs Cloudflare configured in a cell stack.
data "cloudflare_ip_ranges" "cf" {}

module "cell" {
  source           = "../../../modules/cell"
  cloud            = var.cloud
  profile          = var.profile
  env              = var.env
  region           = var.region
  shape            = var.shape
  node_max         = var.node_max
  admin_cidrs      = var.admin_cidrs
  cloudflare_ipv4  = data.cloudflare_ip_ranges.cf.ipv4_cidrs
  ci_role_arn      = var.ci_role_arn
}

output "cell" {
  value = module.cell.cell
}

output "cluster" {
  value     = module.cell.cluster
  sensitive = true
}

output "database" {
  value     = module.cell.database
  sensitive = true
}

output "cache" {
  value     = module.cell.cache
  sensitive = true
}
```
`cloudflare_ip_ranges` needs the `cloudflare` provider in `required_providers` of this stack; the data source is public and needs no token. `variables.tf` in the stack declares the same keys as `terraform.tfvars` with no defaults, so a missing value fails at plan time.

```hcl
# infra/live/aws-prod/10-foundation/terraform.tfvars
cloud       = "aws"
profile     = "managed"
env         = "prod"
region      = "ap-south-1"
shape       = "small"
node_max    = 5
admin_cidrs = ["203.0.113.10/32"]
ci_role_arn = "arn:aws:iam::111122223333:role/cb-apply-aws-prod"
```

```hcl
# infra/live/aws-prod/10-foundation/backend.tf
terraform {
  backend "s3" {
    bucket       = "cb-tfstate-aws"
    key          = "aws-prod/10-foundation.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

```hcl
# infra/live/gcp-prod/10-foundation/backend.tf
terraform {
  backend "gcs" {
    bucket = "cb-tfstate-gcp"
    prefix = "gcp-prod/10-foundation"
  }
}
```

### 7b. Budget live stacks (implemented and validated in Week 1)

`infra/live/{aws,gcp}-budget/10-foundation`. Two things the prod example above glosses over, both proven by an offline `terraform test` per stack (`tests/stack.tftest.hcl`: the stack's own cloud mocked, the other cloud's provider running for real with its placeholder config):

1. **The other cloud's provider is still configured.** The facade wires both clouds' implementations (`count = 0` for the other one), so Terraform configures *both* providers in every stack. Give the unused one an explicit placeholder so it never looks for credentials the stack doesn't have:

```hcl
# infra/live/aws-budget/10-foundation/providers.tf
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "cloudbridge"
    }
  }
}

# The cell facade wires the GCP implementations too (with count = 0 here), so Terraform still
# configures the google provider in this stack. It never makes a call; a placeholder token stops
# it from searching for credentials an AWS stack doesn't have. (Leaky abstraction: one facade,
# two providers per stack.)
provider "google" {
  project      = "unused-in-an-aws-cell"
  access_token = "unused-in-an-aws-cell"
}
```

```hcl
# infra/live/gcp-budget/10-foundation/providers.tf
provider "google" {
  project = var.gcp_project_id
  region  = var.region
}

# The cell facade wires the AWS implementations too (with count = 0 here), so Terraform still
# configures the aws provider in this stack. It never makes a call; these settings stop it from
# validating credentials or calling STS/IMDS. (Leaky abstraction: one facade, two providers per stack.)
provider "aws" {
  region                      = "ap-south-1"
  access_key                  = "unused-in-a-gcp-cell"
  secret_key                  = "unused-in-a-gcp-cell"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}
```

2. **Cloudflare ranges without Cloudflare credentials.** `data "cloudflare_ip_ranges"` needs the Cloudflare provider configured in every cell stack. The ranges are published at a public URL, so read them with the `http` provider and refuse to build an origin firewall if the fetch fails:

```hcl
# infra/live/aws-budget/10-foundation/main.tf
# Cloudflare publishes its origin ranges at a public URL; reading them needs no Cloudflare token,
# so a cell stack never holds Cloudflare credentials. Origins accept 443 only from these ranges.
data "http" "cloudflare_ipv4" {
  url = "https://www.cloudflare.com/ips-v4"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && length(trimspace(self.response_body)) > 0
      error_message = "Could not read Cloudflare's IPv4 ranges; refusing to build an origin firewall without them."
    }
  }
}

locals {
  cloudflare_ipv4 = compact(split("\n", trimspace(data.http.cloudflare_ipv4.response_body)))
}

module "cell" {
  source          = "../../../modules/cell"
  cloud           = var.cloud
  profile         = var.profile
  env             = var.env
  region          = var.region
  shape           = var.shape
  gcp_project_id  = var.gcp_project_id
  cloudflare_ipv4 = local.cloudflare_ipv4
}
```

```hcl
# infra/live/aws-budget/10-foundation/tests/stack.tftest.hcl
# Offline proof that this stack plans: AWS is mocked, the google provider runs with its real
# placeholder configuration (it must not need credentials), and the Cloudflare ranges are overridden.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
    }
  }
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
}

override_data {
  target = data.http.cloudflare_ipv4
  values = {
    status_code   = 200
    response_body = "173.245.48.0/20\n103.21.244.0/22\n"
  }
}

run "aws_budget_cell_plans_offline" {
  command = plan

  assert {
    condition     = output.cell.cloud == "aws" && output.cell.profile == "budget"
    error_message = "The AWS budget stack must build an AWS budget cell."
  }

  assert {
    condition     = output.cell.shape.mem_gib == 2
    error_message = "Budget cells use the 2 GiB shape pair."
  }
}
```

**Mock-provider lessons from making the contract test actually run** (it had only been format-checked before):
- Mock only *computed* attributes. A default for a configured block (`vpc_config` on `aws_eks_cluster`) is rejected.
- Values a provider validates still need a realistic shape under mocks: `aws_iam_policy_document.json = "{}"`, IAM role `arn`, and a network self-link for `google_compute_network.id` (Cloud SQL's `private_network` regex).
- Resources with `prevent_destroy` (RDS, Cloud SQL, caches) can't be torn down by `terraform test`, so the managed-profile runs use `command = plan`; the budget runs `apply`.
- Don't hard-index optional computed blocks in outputs (`master_auth[0]` is empty until GKE fills it); wrap them in `try()`.

The AWS k3s module also creates the **SSM transfer bucket** Ansible's `aws_ssm` connection needs (`cluster.auth.transfer_bucket`); the reference had pointed at a bucket nothing created.

## 8. Budget-profile bootstrap

Managed cells: `20-bootstrap` installs Argo CD with one `helm_release` and applies the rendered root ApplicationSet.

Budget cells: the k3s API is never exposed, so the bootstrap is done by Ansible writing two files into `/var/lib/rancher/k3s/server/manifests/` (k3s auto-applies that directory): a `HelmChart` for Argo CD and the rendered root ApplicationSet. Same Argo CD chart version, same ApplicationSet template, different delivery mechanism — and still exactly one owner per object. See cloudbridge-ansible-ops.
