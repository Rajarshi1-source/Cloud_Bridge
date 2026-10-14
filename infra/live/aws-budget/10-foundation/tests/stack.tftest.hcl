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
