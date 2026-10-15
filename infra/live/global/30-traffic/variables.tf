variable "zone_id" {
  type        = string
  description = "Cloudflare zone of the domain in gitops/global/values.yaml."
}

variable "account_id" {
  type = string
}

variable "weights" {
  type        = map(number)
  description = "Percent of traffic per cell. Changed only by PR, the steering recommender's PR, or the evacuation playbook."

  validation {
    condition     = sum(values(var.weights)) == 100
    error_message = "Weights must sum to 100."
  }

  validation {
    condition     = alltrue([for w in values(var.weights) : w == 0 || w >= 10])
    error_message = "Each cell must be 0 (drained) or >= 10 (warm floor): a cell at 3% has cold caches and a scaled-in pool."
  }

  validation {
    condition     = length(setsubtract(keys(var.weights), ["aws", "gcp"])) == 0 && length(var.weights) == 2
    error_message = "Weights need exactly the keys aws and gcp."
  }
}

variable "fallback_cell" {
  type        = string
  default     = "gcp"
  description = "Pool Cloudflare uses when every pool looks unhealthy."

  validation {
    condition     = contains(["aws", "gcp"], var.fallback_cell)
    error_message = "fallback_cell must be aws or gcp."
  }
}

# Where each cell's origin comes from. Budget cells: the VM's static IP from 10-foundation.
# Managed AWS: the ALB hostname from 20-bootstrap (the controller creates the ALB, so it only
# exists after bootstrap — a documented leaky abstraction).
variable "aws_origin_state_key" {
  type    = string
  default = "aws-budget/10-foundation.tfstate"
}

variable "gcp_origin_state_prefix" {
  type    = string
  default = "gcp-budget/10-foundation"
}
