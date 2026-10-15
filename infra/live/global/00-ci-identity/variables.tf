variable "github_repository" {
  type        = string
  description = "owner/name: the only repository whose workflows may assume these identities."
}

variable "gcp_project_id" {
  type = string
}

variable "aws_state_bucket" {
  type = string
}

variable "gcp_state_bucket" {
  type = string
}
