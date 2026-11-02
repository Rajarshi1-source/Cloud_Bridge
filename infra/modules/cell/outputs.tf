output "cell" {
  value = {
    name         = local.name
    cloud        = var.cloud
    profile      = var.profile
    region       = var.region
    shape        = local.shape_row
    origin       = local.cluster.origin
    image_mirror = local.image_mirror
    expires_at   = var.expires_at # read by the TTL reaper from state; null = never
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

output "secret_store" {
  value = local.secret_store
}
