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
  description = "Cloudflare origin ranges (data.cloudflare_ip_ranges.cf.ipv4_cidrs passed in by the stack)."
}

variable "managed_cache" {
  type    = bool
  default = true
}

variable "ci_role_arn" {
  type        = string
  default     = null
  description = "AWS only: CI role granted an EKS access entry."
}
