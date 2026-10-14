output "cell" {
  value = module.cell.cell
}

output "cluster" {
  value     = module.cell.cluster
  sensitive = true
}
