variable "name" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  type = string
}

variable "desired" {
  type = number
}

variable "max" {
  type = number
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public API endpoint. Never empty or 0.0.0.0/0: enforced by the cell facade's guards."
}

variable "ci_role_arn" {
  type    = string
  default = null
}

variable "admin_arns" {
  type        = list(string)
  default     = []
  description = "IAM principals given cluster-admin through access entries (bootstrap_cluster_creator_admin_permissions is off)."
}

variable "tags" {
  type = map(string)
}
