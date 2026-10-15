# Offline proof that the ephemeral EKS stack plans with its real tfvars: AWS is mocked, the google
# provider runs with its placeholder configuration (it must not need credentials).
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
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
  # OpenTofu generates mock values at plan time too, and EKS validates its role_arn as an ARN.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/cb-mock"
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      certificate_authority = [{ data = "Y2E=" }]
    }
  }
}

variables {
  expires_at  = "1792180800"
  admin_cidrs = ["203.0.113.10/32"]
}

run "aws_ephemeral_cell_plans_offline" {
  command = plan

  assert {
    condition     = output.cell.profile == "managed" && output.expires_at == "1792180800"
    error_message = "The AWS dev stack must be a managed cell that carries its expiry."
  }
}

run "expiry_is_required" {
  command = plan
  variables {
    expires_at = "soon"
  }
  expect_failures = [var.expires_at]
}
