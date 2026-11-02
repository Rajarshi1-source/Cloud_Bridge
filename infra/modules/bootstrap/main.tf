# Argo CD and the root ApplicationSet on a managed cell: the only things Terraform puts in a cluster.
# The same chart version and ApplicationSet template as the budget cells' Ansible role.
variable "cell" {
  type = string
}

variable "ring" {
  type = string
  validation {
    condition     = contains(["ring-canary", "ring-main"], var.ring)
    error_message = "ring must be ring-canary or ring-main."
  }
}

variable "argocd_chart_version" {
  type    = string
  default = "10.10.5" # = argocd_autodeploy_chart_version (Argo CD v3.5.5)
}

locals {
  appset = templatefile("${path.module}/../../../gitops/bootstrap/applicationset.yaml.tftpl", {
    cell = var.cell
    ring = var.ring
  })
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true
  values = [yamlencode({
    dex           = { enabled = false }
    notifications = { enabled = false }
    configs       = { params = { "server.insecure" = true } }
    server        = { service = { type = "ClusterIP" } } # reached by port-forward, never exposed
  })]
}

# A local chart rather than kubernetes_manifest: that resource needs the ApplicationSet CRD to exist
# at plan time, which it can't on a new cluster.
resource "helm_release" "root_appset" {
  name       = "cloudbridge-root"
  namespace  = "argocd"
  chart      = "${path.module}/chart"
  values     = [yamlencode({ manifest = local.appset })]
  depends_on = [helm_release.argocd]
}

output "argocd_chart_version" {
  value = var.argocd_chart_version
}

output "root_appset" {
  value = local.appset
}
