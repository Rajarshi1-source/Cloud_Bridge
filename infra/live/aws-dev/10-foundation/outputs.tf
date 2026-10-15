output "cell" {
  value = module.cell.cell
}

output "cluster" {
  value     = module.cell.cluster
  sensitive = true
}

# The TTL reaper reads this from state; the cb-expires-at label carries the same value for consoles
# and the cost ledger.
output "expires_at" {
  value = module.cell.cell.expires_at
}
