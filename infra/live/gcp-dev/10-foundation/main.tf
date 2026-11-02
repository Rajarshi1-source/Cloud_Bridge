module "cell" {
  source               = "../../../modules/cell"
  cloud                = var.cloud
  profile              = var.profile
  env                  = var.env
  region               = var.region
  shape                = var.shape
  node_count           = var.node_count
  node_max             = var.node_max
  gcp_project_id       = var.gcp_project_id
  admin_cidrs          = var.admin_cidrs
  admin_principal_arns = var.admin_principal_arns
  dockerhub_user       = var.dockerhub_user
  expires_at           = var.expires_at
  admin_access         = var.admin_access
  # Ephemeral: Postgres and Valkey run in-cluster. Managed data services carry prevent_destroy and
  # would make the cell impossible to reap (the facade refuses that combination).
  managed_data  = false
  managed_cache = false
}
