output "lb_id" {
  value = cloudflare_load_balancer.app.id
}

# tools/cf_break_glass.py (Week 7) needs these to patch weights when this state is unreachable.
output "pool_ids" {
  value = { for k, p in cloudflare_load_balancer_pool.cell : k => p.id }
}

output "weights" {
  value = var.weights
}

output "hostname" {
  value = local.hostname
}

# The gateway and inventory-service validate Cf-Access-Jwt-Assertion against this audience.
output "admin_access_aud" {
  value = cloudflare_zero_trust_access_application.admin.aud
}

# The lease allocator authenticates with these (stored in GCP Secret Manager, never in Git).
output "allocator_client_id" {
  value = cloudflare_zero_trust_access_service_token.allocator.client_id
}

output "allocator_client_secret" {
  value     = cloudflare_zero_trust_access_service_token.allocator.client_secret
  sensitive = true
}
