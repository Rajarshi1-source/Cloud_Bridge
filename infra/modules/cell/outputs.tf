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
