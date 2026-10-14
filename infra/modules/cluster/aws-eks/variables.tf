variable "name" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "vpc_id" {
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
  type = list(string)
}

variable "ci_role_arn" {
  type    = string
  default = null
}

variable "tags" {
  type = map(string)
}
