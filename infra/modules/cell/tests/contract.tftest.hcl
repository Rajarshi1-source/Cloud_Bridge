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
