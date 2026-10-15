# ECR pull-through cache for Docker Hub: nodes pull <acct>.dkr.ecr.<region>.amazonaws.com/dockerhub/
# <user>/cb-<svc>@sha256:…, ECR fetches it from Docker Hub once and serves it from the region after.
# Rate limits and a Docker Hub outage leave the pod-start path during an evacuation scale-up.

variable "region" {
  type = string
}

variable "credentials_secret" {
  type        = string
  description = "Secrets Manager secret holding {\"username\": …, \"accessToken\": …}; ECR requires the ecr-pullthroughcache/ name prefix."
  validation {
    condition     = startswith(var.credentials_secret, "ecr-pullthroughcache/")
    error_message = "ECR only reads upstream credentials from secrets named ecr-pullthroughcache/…"
  }
}

data "aws_caller_identity" "this" {}

# Created by the operator (docs/runbooks/week-2-go-live.md): the token never passes through state.
data "aws_secretsmanager_secret" "dockerhub" {
  name = var.credentials_secret
}

resource "aws_ecr_pull_through_cache_rule" "dockerhub" {
  ecr_repository_prefix = "dockerhub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = data.aws_secretsmanager_secret.dockerhub.arn
}

output "prefix" {
  value = "${data.aws_caller_identity.this.account_id}.dkr.ecr.${var.region}.amazonaws.com/${aws_ecr_pull_through_cache_rule.dockerhub.ecr_repository_prefix}"
}
