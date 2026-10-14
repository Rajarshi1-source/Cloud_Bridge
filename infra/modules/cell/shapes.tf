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
