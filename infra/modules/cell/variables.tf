variable "cloud" {
  type        = string
  description = "Target cloud for this cell."
  validation {
    condition     = contains(["aws", "gcp"], var.cloud)
    error_message = "cloud must be \"aws\" or \"gcp\"."
  }
}

variable "profile" {
  type    = string
  default = "managed"
  validation {
    condition     = contains(["managed", "budget"], var.profile)
    error_message = "profile must be \"managed\" or \"budget\"."
  }
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "shape" {
  type    = string
  default = "small"
}

variable "kubernetes_minor" {
  type    = string
  default = "1.36"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "node_max" {
  type        = number
  default     = 5
  description = "Sized so this cell can absorb 100% of traffic during an evacuation."
}

variable "gcp_project_id" {
  type    = string
  default = null
}

variable "admin_cidrs" {
  type    = list(string)
  default = []
}

variable "cloudflare_ipv4" {
  type        = list(string)
  default     = []
  description = "Cloudflare origin ranges the budget VM firewall admits on 443. Required for budget; managed cells sit behind a cloud load balancer instead."
}

variable "managed_cache" {
  type    = bool
  default = true
}

variable "managed_data" {
  type        = bool
  default     = true
  description = "Managed profile only: create RDS / Cloud SQL (and the cache, with managed_cache). Ephemeral cells set false and run Postgres and Valkey in-cluster, because managed data services carry prevent_destroy and could never be reaped."
}

variable "expires_at" {
  type        = string
  default     = null
  description = "Unix epoch seconds after which the TTL reaper destroys this cell (label cb-expires-at). Ephemeral cells only; never set on prod."
  validation {
    condition     = var.expires_at == null || can(regex("^[0-9]{10}$", var.expires_at))
    error_message = "expires_at must be Unix epoch seconds (10 digits)."
  }
}

variable "admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "AWS only: IAM principals given EKS cluster-admin through access entries (the operator, the ephemeral CI role). The aws-auth ConfigMap is never used."
}

variable "image_mirror" {
  type        = bool
  default     = true
  description = "Managed profile: create the pull-through registry mirror (ECR pull-through cache / Artifact Registry remote repository) for Docker Hub."
}

variable "dockerhub_credentials_secret" {
  type        = string
  default     = "ecr-pullthroughcache/cb-dockerhub"
  description = "AWS: Secrets Manager secret ({username, accessToken}) the ECR pull-through rule authenticates to Docker Hub with. The ecr-pullthroughcache/ prefix is required by ECR."
}

variable "ci_role_arn" {
  type        = string
  default     = null
  description = "AWS only: CI role granted an EKS access entry."
}

variable "dockerhub_user" {
  type        = string
  default     = null
  description = "GCP: Docker ID for the Artifact Registry remote repository's upstream credentials (token = latest version of Secret Manager secret cb-dockerhub-pull). Null pulls anonymously (rate-limited)."
}
