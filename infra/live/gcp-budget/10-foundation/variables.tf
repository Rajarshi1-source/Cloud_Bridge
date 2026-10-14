# No defaults for the cell's identity: a missing tfvars value must fail at plan time.
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

variable "gcp_project_id" {
  type    = string
  default = null
}
