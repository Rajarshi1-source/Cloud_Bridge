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
  # ECR validates the pull-through rule's credential_arn as an ARN.
  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-south-1:111122223333:secret:ecr-pullthroughcache/cb-dockerhub-AbCdEf"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
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
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_compute_network" {
    defaults = {
      id = "projects/cb-test/global/networks/cb-gcp-test"
    }
  }
  # No defaults for google_container_cluster.master_auth or google_memorystore_instance.endpoints:
  # OpenTofu validates mock values against the full schema (a block can't take a list; every
  # required nested field must be given), and Terraform never applied them anyway. The GKE output
  # tolerates an empty master_auth with try(), and the managed runs use plan, where endpoints stay unknown.
}

mock_provider "random" {}

variables {
  env             = "test"
  region          = "ap-south-1"
  cloudflare_ipv4 = ["173.245.48.0/20"]
  gcp_project_id  = "cb-test"
  admin_cidrs     = ["203.0.113.10/32"]
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
  assert {
    condition     = output.cell.image_mirror == "111122223333.dkr.ecr.ap-south-1.amazonaws.com/dockerhub"
    error_message = "Managed AWS cells pull through the ECR pull-through cache."
  }
  assert {
    condition     = alltrue([for k in ["host", "port", "secret_ref"] : contains(keys(output.database), k)]) && alltrue([for k in ["host", "port", "tls"] : contains(keys(output.cache), k)])
    error_message = "AWS managed data contract keys missing."
  }
  assert {
    condition     = output.secret_store.kind == "aws" && output.secret_store.prefix == "cb-aws-test" && contains(keys(output.secret_store), "reader")
    error_message = "A managed AWS cell exposes the store External Secrets reads."
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
  assert {
    condition     = output.cell.image_mirror == "asia-south1-docker.pkg.dev/cb-test/dockerhub"
    error_message = "Managed GCP cells pull through the Artifact Registry remote repository."
  }
  assert {
    condition     = alltrue([for k in ["host", "port", "secret_ref"] : contains(keys(output.database), k)]) && alltrue([for k in ["host", "port", "tls"] : contains(keys(output.cache), k)])
    error_message = "GCP managed data contract keys missing."
  }
  assert {
    condition     = output.secret_store.kind == "gcp" && output.secret_store.prefix == "cb-gcp-test" && contains(keys(output.secret_store), "reader")
    error_message = "A managed GCP cell exposes the store External Secrets reads."
  }
}

run "managed_cache_toggle" {
  command = plan
  variables {
    cloud         = "gcp"
    profile       = "managed"
    region        = "asia-south1"
    managed_cache = false
  }
  assert {
    condition     = output.database != null && output.cache == null
    error_message = "managed_cache = false keeps the managed database and leaves Valkey in the cluster."
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
  assert {
    condition     = output.cell.image_mirror == "docker.io" && output.cell.expires_at == null
    error_message = "Budget cells pull docker.io (k3s registry token) and never expire."
  }
  assert {
    condition     = output.secret_store == null
    error_message = "Budget cells get their Secrets from Ansible, not External Secrets."
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

# Ephemeral managed cells (Week 3): apply works because nothing carries prevent_destroy, the expiry
# reaches the outputs the TTL reaper reads, and data runs in-cluster.
run "aws_ephemeral_managed" {
  command = apply
  variables {
    cloud                = "aws"
    profile              = "managed"
    env                  = "dev"
    managed_data         = false
    expires_at           = "1792180800"
    admin_principal_arns = ["arn:aws:iam::111122223333:role/cb-ephemeral-aws"]
  }
  assert {
    condition     = output.database == null && output.cache == null && output.cell.expires_at == "1792180800"
    error_message = "An ephemeral AWS cell has no managed data and carries its expiry."
  }
}

run "gcp_ephemeral_managed" {
  command = apply
  variables {
    cloud        = "gcp"
    profile      = "managed"
    env          = "dev"
    region       = "asia-south1"
    managed_data = false
    expires_at   = "1792180800"
  }
  assert {
    condition     = output.database == null && output.cache == null && output.cluster.auth.kind == "gcp-gke"
    error_message = "An ephemeral GCP cell is a GKE cluster without managed data."
  }
}

run "rejects_managed_without_admin_cidrs" {
  command = plan
  variables {
    cloud       = "gcp"
    region      = "asia-south1"
    admin_cidrs = []
  }
  expect_failures = [terraform_data.guards]
}

run "rejects_world_open_api" {
  command = plan
  variables {
    cloud       = "aws"
    admin_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [terraform_data.guards]
}

run "rejects_expiring_prod" {
  command = plan
  variables {
    cloud        = "aws"
    env          = "prod"
    managed_data = false
    expires_at   = "1792180800"
  }
  expect_failures = [terraform_data.guards]
}

run "rejects_expiring_cell_with_managed_data" {
  command = plan
  variables {
    cloud      = "aws"
    env        = "dev"
    expires_at = "1792180800"
  }
  expect_failures = [terraform_data.guards]
}

run "rejects_budget_without_cloudflare_ranges" {
  command = plan
  variables {
    cloud           = "aws"
    profile         = "budget"
    cloudflare_ipv4 = []
  }
  expect_failures = [terraform_data.guards]
}

run "rejects_malformed_expiry" {
  command = plan
  variables {
    cloud        = "aws"
    env          = "dev"
    managed_data = false
    expires_at   = "2026-10-16T20:00:00Z"
  }
  expect_failures = [var.expires_at]
}

run "rejects_unknown_cloud" {
  command = plan
  variables {
    cloud = "azure"
  }
  expect_failures = [var.cloud]
}
