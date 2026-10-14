variable "name" {
  type = string
}

variable "env" {
  type = string
}

variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "machine_type" {
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

variable "labels" {
  type = map(string)
}
