# Ephemeral managed cell: created by `make managed-up` or ephemeral-up.yml for at most 8 hours, then
# destroyed by the TTL reaper. No defaults for identity or lifetime: a missing value fails at plan.
variable "cloud" {
  type = string
}

variable "profile" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type = string
}

variable "shape" {
  type = string
}

variable "node_count" {
  type = number
}

variable "node_max" {
  type = number
}

variable "gcp_project_id" {
  type    = string
  default = null
}

# Set per run (TF_VAR_expires_at): Unix epoch seconds, at most 8 h ahead (the Makefile and
# ephemeral-up.yml compute and cap it).
variable "expires_at" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{10}$", var.expires_at))
    error_message = "expires_at must be Unix epoch seconds (date -u -d '+4 hours' +%s), at most 8 hours ahead."
  }
}

# Set per run (TF_VAR_admin_cidrs): the operator's or runner's address, never 0.0.0.0/0.
variable "admin_cidrs" {
  type = list(string)
}

variable "admin_principal_arns" {
  type    = list(string)
  default = []
}

variable "dockerhub_user" {
  type    = string
  default = null
}
