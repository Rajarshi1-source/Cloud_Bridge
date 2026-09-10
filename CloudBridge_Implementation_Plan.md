# CloudBridge — Multi-Cloud Deployment Automation (AWS + GCP) with Terraform

## Complete Implementation Plan for Junior DevOps Engineer Interview (2026)

---

## Table of Contents

1. Project Overview & Interview Hook
2. Tech Stack (with justification for every choice)
3. MVP Blueprint (7-week plan)
4. System Design — High Level Design (HLD)
5. System Design — Low Level Design (LLD)
6. Database Design & Choice (with comparison matrix)
7. Caching & Messaging — Redis vs Kafka vs RabbitMQ (verdict)
8. Design Patterns Used
9. Docker & Kubernetes Deployment Strategy
10. CI/CD Pipeline (GitHub Actions → Both Clouds)
11. Monitoring & Observability
12. README Blueprint with Architecture Diagram
13. Interview Prep — Questions & Answers (IaC + Multi-Cloud focused)
14. Week-by-Week Build Schedule

---

## 1. Project Overview & Interview Hook

**Project Name:** CloudBridge

**Tagline:** "One codebase. Two clouds. Zero vendor lock-in."

**One-liner:** A multi-cloud deployment automation platform where identical Terraform modules deploy the same Spring Boot microservices application to both AWS EKS and GCP GKE from a single codebase, managed through GitHub Actions with environment-specific Terraform workspaces, traffic split 70% AWS / 30% GCP via Cloudflare global load balancer, with a real-time cost comparison dashboard built in Next.js + Grafana showing per-service spend across both clouds — proving you can switch clouds by changing one Terraform variable.

**Interview Hook (memorize this):**

> "I built a multi-cloud deployment platform where the same Spring Boot microservices run on both AWS EKS and GCP GKE, deployed from one Terraform codebase. Changing `var.cloud_provider` from 'aws' to 'gcp' deploys identical infrastructure — VPC, Kubernetes cluster, load balancers, databases, monitoring — to a different cloud. Traffic splits 70/30 via Cloudflare. The cost dashboard shows AWS costs ₹18,500/month versus GCP at ₹14,200/month for the same workload — that data drives real migration decisions. I used PostgreSQL for the cost and deployment metadata because it's relational — deployments belong to environments which belong to clouds which have cost line items. I chose Redis over Kafka for the deployment event queue because my event volume is under 50 deployments per day. The entire pipeline runs in GitHub Actions with Terraform workspaces separating AWS and GCP state."

**Why DevOps interviewers love this:**
- **Multi-cloud Terraform is on every senior DevOps JD** — you're demonstrating a senior-level skill as a fresher
- **Infrastructure-as-Code mastery** — modules, workspaces, state management, provider abstraction
- **AWS + GCP hands-on** — not theoretical; you deployed real infrastructure to both clouds
- **Cost engineering** — FinOps is the hottest cloud topic in 2026 India
- **Cloudflare traffic management** — DNS-level failover + weighted routing
- **No vendor lock-in by design** — shows architectural thinking, not just tooling

**Target Companies:**
- **Razorpay, Flipkart, Swiggy** — multi-cloud strategies for reliability + cost optimization
- **Atlassian India** — Terraform + K8s at massive scale
- **Nutanix, VMware/Broadcom** — multi-cloud infrastructure is their business
- **HashiCorp partners** — companies using Terraform Cloud/Enterprise
- **Freshworks, Zoho** — SaaS companies evaluating multi-cloud
- **Any DevOps/Platform Engineering role** — Terraform is the #1 IaC skill

---

## 2. Tech Stack — Every Choice Justified

### Core Stack

| Layer | Technology | Why This (Interview Answer) |
|---|---|---|
| **Infrastructure-as-Code** | Terraform 1.7+ (HCL) | Industry standard for multi-cloud IaC. Provider-agnostic — same HCL syntax provisions AWS, GCP, Azure. Modules enable reuse. State management for drift detection. 70%+ of DevOps JDs in India require Terraform. |
| **AWS Kubernetes** | Amazon EKS (Elastic Kubernetes Service) | Managed K8s on AWS. Terraform `aws_eks_cluster` resource. VPC + subnets + node groups fully IaC-managed. |
| **GCP Kubernetes** | Google GKE (Google Kubernetes Engine) | Managed K8s on GCP. Terraform `google_container_cluster` resource. Best managed K8s in the industry (GKE Autopilot). |
| **Global Load Balancer** | Cloudflare DNS + Load Balancing | Weighted DNS routing: 70% → AWS ALB, 30% → GCP LB. Health checks on both endpoints. Instant failover if one cloud goes down. Free tier available. |
| **Application** | Spring Boot 3.x (Java 21) microservices | Enterprise standard in Bangalore. 3 microservices: API Gateway, Order Service, Inventory Service. Same Docker images deploy to both clouds. |
| **Container Registry** | DockerHub (cross-cloud) | Single registry accessible from both AWS and GCP. Images tagged with git SHA for traceability. |
| **Dashboard** | Next.js 14 + Grafana | Next.js for custom cost comparison dashboard. Grafana for infrastructure metrics (CPU/memory/network per cloud). |
| **Cost Data** | AWS Cost Explorer API + GCP Billing API | Pulls per-service cost data from both clouds. Normalizes into a unified cost model. |
| **Database** | PostgreSQL 16 | See Section 6. Deployment metadata, cost records, environment configs — all relational. |
| **Cache** | Redis 7 | See Section 7. Dashboard cache, Terraform state lock coordination, deployment event queue. |
| **CI/CD** | GitHub Actions | Terraform plan/apply orchestration. Environment-specific workflows. Manual approval gates for production. |
| **Secrets** | HashiCorp Vault (or GitHub Secrets) | AWS credentials, GCP service account keys, Cloudflare API tokens — all managed securely. |
| **Monitoring** | Prometheus + Grafana (per cloud) + unified Grafana | Each cloud runs Prometheus. A central Grafana queries both for unified view. |
| **DNS** | Cloudflare | Domain management + CDN + weighted DNS for traffic splitting. |

### Why NOT These Alternatives

| Rejected Option | Why |
|---|---|
| Pulumi | Pulumi uses general-purpose languages (Python, TypeScript, Go) for IaC. Terraform's HCL is purpose-built for infrastructure and is the industry standard — 70%+ of DevOps JDs require Terraform, not Pulumi. For interview value, Terraform wins decisively. |
| AWS CloudFormation | AWS-only. The entire point of this project is multi-cloud. CloudFormation can't provision GCP resources. |
| Google Cloud Deployment Manager | GCP-only. Same problem as CloudFormation. |
| Ansible for provisioning | Ansible is configuration management (post-provisioning), not infrastructure provisioning. Terraform creates the VPC, EKS cluster, and node groups. Ansible would configure software on existing servers. Different layer. |
| Crossplane | Kubernetes-native IaC. Requires a running K8s cluster to provision infrastructure — chicken-and-egg problem. Terraform provisions the cluster itself. |
| AWS Route 53 for DNS | AWS-specific. Cloudflare provides cloud-neutral DNS with weighted routing, free SSL, and a CDN — all accessible from both clouds. Route 53 would create AWS dependency in the traffic layer. |
| Azure (as third cloud) | Two clouds demonstrate the pattern perfectly. Adding Azure triples the Terraform code, triples the cost, and triples the testing burden without adding interview value. Mention "the architecture supports adding Azure as a third provider" in interviews. |
| MongoDB | Cost records are relational: cloud_provider → service → resource → daily_cost. Deployments link to environments which link to Terraform workspaces. JOINs are essential. |
| TimescaleDB | Cost data is collected daily (not per-second). 365 cost records per service per year is trivial for PostgreSQL. TimescaleDB's time-series optimizations add complexity for zero benefit at this frequency. |

---

## 3. MVP Blueprint — 7-Week Build Plan

### MVP Scope

**Must Have:**
- Terraform modules: VPC/Network, Kubernetes Cluster, Ingress/LB, Monitoring — all cloud-agnostic with provider-specific implementations
- Deploy 3 Spring Boot microservices to both AWS EKS and GCP GKE from one codebase
- GitHub Actions pipeline: `terraform plan` on PR, `terraform apply` on merge, per-cloud workspaces
- Cloudflare weighted DNS: 70% AWS, 30% GCP with health checks
- Cost comparison dashboard: per-service spend AWS vs GCP
- Grafana multi-cloud metrics: CPU/memory/network from both Prometheus instances
- Docker Compose for local development
- Helm charts for the microservices
- Documentation: architecture diagram, Terraform module docs, setup guide

**Nice to Have (Post-MVP):**
- Terraform Cloud remote state with locking
- Infracost integration (cost estimation before apply)
- Automated cloud migration runbook (shift traffic 100% to one cloud)
- OPA policy checks on Terraform plans (e.g., "no public S3 buckets")
- Disaster recovery: automatic failover if one cloud goes unhealthy
- Blue/green deployments across clouds
- Azure as third cloud provider

### The Sample Microservices App (What We're Deploying)

3 Spring Boot services designed to demonstrate multi-cloud patterns:

| Service | Purpose | Resources | Cross-Cloud Pattern |
|---|---|---|---|
| `api-gateway` | Routes traffic to downstream services | 2 replicas, 200m CPU, 256MB | Identical deployment on both clouds — Cloudflare routes to both |
| `order-service` | CRUD for orders + connects to PostgreSQL | 2 replicas, 500m CPU, 512MB | Database per cloud (RDS on AWS, Cloud SQL on GCP) — shows managed DB abstraction |
| `inventory-service` | Cache-heavy read service + Redis | 2 replicas, 200m CPU, 256MB | Managed Redis per cloud (ElastiCache on AWS, Memorystore on GCP) |

### Week-by-Week Schedule

**Week 1 — Terraform Foundation + Networking**
- Day 1–2: Terraform project structure: root module, cloud-specific modules, shared variables
- Day 3–4: AWS VPC module: VPC, public/private subnets, NAT gateway, security groups
- Day 5–6: GCP Network module: VPC, subnets, firewall rules, Cloud NAT
- Day 7: Abstract networking interface: same input variables, cloud-specific implementations
- Deliverable: `terraform apply -var="cloud=aws"` creates full network, same for GCP

**Week 2 — Kubernetes Clusters**
- Day 1–2: AWS EKS module: cluster, managed node group, OIDC provider, aws-auth configmap
- Day 3–4: GCP GKE module: cluster, node pool, workload identity
- Day 5: kubectl configuration: auto-generate kubeconfig for both clusters
- Day 6–7: Verify: deploy nginx to both clusters, confirm networking
- Deliverable: K8s clusters running on both clouds, accessible via kubectl

**Week 3 — Spring Boot App + Helm + Deployment**
- Day 1–2: Build 3 Spring Boot microservices, Dockerfiles, push to DockerHub
- Day 3: Helm chart: templates for deployment, service, ingress, configmap
- Day 4–5: Terraform Helm provider: deploy charts to both EKS and GKE
- Day 6: Managed databases: RDS PostgreSQL (AWS) + Cloud SQL (GCP) via Terraform
- Day 7: Managed Redis: ElastiCache (AWS) + Memorystore (GCP) via Terraform
- Deliverable: Full app running on both clouds with managed backing services

**Week 4 — Cloudflare Traffic Management + DNS**
- Day 1–2: Cloudflare Terraform provider: DNS zone, A/CNAME records
- Day 3: Weighted DNS: 70% → AWS ALB external IP, 30% → GCP LB external IP
- Day 4: Health checks: Cloudflare pings `/health` on both endpoints
- Day 5: Failover testing: take down AWS → Cloudflare routes 100% to GCP
- Day 6–7: SSL/TLS configuration via Cloudflare (free certificates)
- Deliverable: `app.cloudbridge.dev` routes traffic across both clouds

**Week 5 — GitHub Actions CI/CD Pipeline**
- Day 1–2: Terraform plan on PR (show diff in PR comment)
- Day 3: Terraform apply on merge to main (per workspace: aws, gcp)
- Day 4: Manual approval gate for production applies
- Day 5: Docker build → push → Helm upgrade in same pipeline
- Day 6: Environment matrix: dev, staging, prod × aws, gcp
- Day 7: Terraform state management: S3 backend (AWS) + GCS backend (GCP)
- Deliverable: Full GitOps pipeline managing both clouds

**Week 6 — Cost Dashboard + Monitoring**
- Day 1–2: AWS Cost Explorer API: per-service tagged cost data
- Day 3: GCP Billing API: per-service labeled cost data
- Day 4: Python cost collector: normalize both APIs into unified model → PostgreSQL
- Day 5: Next.js dashboard: side-by-side cost comparison, per-service breakdown
- Day 6: Grafana: multi-cloud metrics (Prometheus from both clusters)
- Day 7: Cost alerting: notify if one cloud exceeds budget threshold
- Deliverable: "AWS costs ₹18,500/mo vs GCP ₹14,200/mo for same workload"

**Week 7 — Polish, Documentation, Demo**
- Day 1–2: Docker Compose for local development
- Day 3: Terraform module documentation (README per module)
- Day 4: Architecture diagram, screenshots, demo video script
- Day 5: Scaling decision documentation
- Day 6: README with setup guide, architecture, cost comparison screenshots
- Day 7: Record demo video showing one-variable cloud switch
- Deliverable: Complete project with documentation and live demo

---

## 4. High-Level Design (HLD)

### Architecture Overview

```
                         ┌──────────────────────────────┐
                         │         USERS                 │
                         │   app.cloudbridge.dev         │
                         └──────────────┬───────────────┘
                                        │
                                        ▼
                         ┌──────────────────────────────┐
                         │      CLOUDFLARE               │
                         │                              │
                         │  DNS Weighted Routing:        │
                         │  ┌────────┐  ┌────────┐      │
                         │  │  70%   │  │  30%   │      │
                         │  │  AWS   │  │  GCP   │      │
                         │  └───┬────┘  └────┬───┘      │
                         │      │            │          │
                         │  Health Checks on both       │
                         │  SSL/TLS termination         │
                         │  CDN caching                 │
                         └──────┬───────────────┬───────┘
                                │               │
           ┌────────────────────▼──┐     ┌──────▼────────────────────┐
           │      AWS (70%)         │     │      GCP (30%)            │
           │                       │     │                           │
           │  ┌─────────────────┐  │     │  ┌─────────────────────┐  │
           │  │   AWS ALB       │  │     │  │   GCP LB            │  │
           │  │   (Ingress)     │  │     │  │   (Ingress)         │  │
           │  └────────┬────────┘  │     │  └──────────┬──────────┘  │
           │           │           │     │             │              │
           │  ┌────────▼────────┐  │     │  ┌──────────▼──────────┐  │
           │  │   AWS EKS       │  │     │  │   GCP GKE           │  │
           │  │   Kubernetes    │  │     │  │   Kubernetes        │  │
           │  │                 │  │     │  │                     │  │
           │  │  ┌───────────┐  │  │     │  │  ┌───────────────┐  │  │
           │  │  │api-gateway│  │  │     │  │  │api-gateway    │  │  │
           │  │  ├───────────┤  │  │     │  │  ├───────────────┤  │  │
           │  │  │order-svc  │  │  │     │  │  │order-svc      │  │  │
           │  │  ├───────────┤  │  │     │  │  ├───────────────┤  │  │
           │  │  │inventory  │  │  │     │  │  │inventory      │  │  │
           │  │  ├───────────┤  │  │     │  │  ├───────────────┤  │  │
           │  │  │Prometheus │  │  │     │  │  │Prometheus     │  │  │
           │  │  └───────────┘  │  │     │  │  └───────────────┘  │  │
           │  └─────────────────┘  │     │  └─────────────────────┘  │
           │                       │     │                           │
           │  ┌─────────────────┐  │     │  ┌─────────────────────┐  │
           │  │ AWS RDS         │  │     │  │ GCP Cloud SQL       │  │
           │  │ (PostgreSQL)    │  │     │  │ (PostgreSQL)        │  │
           │  └─────────────────┘  │     │  └─────────────────────┘  │
           │  ┌─────────────────┐  │     │  ┌─────────────────────┐  │
           │  │ AWS ElastiCache │  │     │  │ GCP Memorystore     │  │
           │  │ (Redis)         │  │     │  │ (Redis)             │  │
           │  └─────────────────┘  │     │  └─────────────────────┘  │
           └───────────────────────┘     └───────────────────────────┘
                    │                                │
                    │    Cost + Metrics               │
                    ▼                                ▼
           ┌────────────────────────────────────────────────┐
           │        CLOUDBRIDGE CONTROL PLANE                │
           │                                                │
           │  ┌──────────────────┐  ┌────────────────────┐  │
           │  │ Cost Collector   │  │ Next.js Dashboard  │  │
           │  │ (Python)         │  │                    │  │
           │  │ - AWS Cost API   │  │ - Cost comparison  │  │
           │  │ - GCP Billing    │  │ - Deployment log   │  │
           │  │ - Normalize      │  │ - Cloud health     │  │
           │  └───────┬──────────┘  └────────┬───────────┘  │
           │          │                      │              │
           │  ┌───────▼──────────────────────▼───────────┐  │
           │  │  PostgreSQL 16      │    Redis 7         │  │
           │  │  (costs, deploys,   │    (cache, queue)  │  │
           │  │   environments)     │                    │  │
           │  └─────────────────────┴────────────────────┘  │
           │                                                │
           │  ┌──────────────────────────────────────────┐  │
           │  │  Grafana (Unified Multi-Cloud Metrics)   │  │
           │  │  ← Prometheus AWS + Prometheus GCP       │  │
           │  └──────────────────────────────────────────┘  │
           └────────────────────────────────────────────────┘
```

### Core Request Flows

**Flow 1: Developer Deploys to Both Clouds (GitOps)**
```
Step 1:  Developer pushes Terraform change (e.g., scale order-service replicas to 4)
    ↓
Step 2:  GitHub Actions triggers on PR:
         Job 1: terraform init -backend-config="aws.tfbackend"
                terraform plan -var="cloud=aws" → post plan diff to PR comment
         Job 2: terraform init -backend-config="gcp.tfbackend"
                terraform plan -var="cloud=gcp" → post plan diff to PR comment
    ↓
Step 3:  Reviewer sees BOTH cloud diffs in the PR:
         "AWS: Scale deployment/order-service replicas 2 → 4"
         "GCP: Scale deployment/order-service replicas 2 → 4"
    ↓
Step 4:  Merge to main → GitHub Actions:
         Job 1: terraform apply -var="cloud=aws" -auto-approve
         Job 2: terraform apply -var="cloud=gcp" -auto-approve
         (Production: requires manual approval step)
    ↓
Step 5:  Both EKS and GKE now running 4 replicas of order-service
    ↓
Step 6:  Cloudflare health checks confirm both endpoints healthy
         Traffic continues: 70% AWS, 30% GCP
    ↓
Step 7:  Deployment recorded in PostgreSQL:
         { cloud: "aws", service: "order-service", change: "scale 2→4",
           terraform_workspace: "aws-prod", commit_sha: "abc123" }
```

**Flow 2: Cloud Provider Switch (The Demo Moment)**
```
Step 1:  Current state: 70% AWS / 30% GCP
    ↓
Step 2:  Change ONE Terraform variable:
         cloudflare_weights = { aws = 0, gcp = 100 }
    ↓
Step 3:  terraform apply → Cloudflare DNS weight changes
    ↓
Step 4:  Within 60 seconds: 100% traffic now on GCP
         AWS infrastructure still running (hot standby)
    ↓
Step 5:  Dashboard shows: "Traffic: AWS 0% | GCP 100%"
         "AWS cost dropping (no traffic), GCP cost stable"
    ↓
Step 6:  To migrate back: change weights to { aws = 100, gcp = 0 }
    ↓
INTERVIEW LINE: "I can shift all production traffic between clouds
                 by changing one variable and running terraform apply.
                 That's zero-vendor-lock-in in action."
```

**Flow 3: Cost Data Collection**
```
Step 1:  Daily cron (GitHub Actions or K8s CronJob):
    ↓
Step 2:  AWS Cost Collector:
         → AWS Cost Explorer API: get daily cost per service tag
         → Filter by tags: Service=api-gateway, Environment=prod
         → Returns: { service: "api-gateway", daily_cost_usd: 2.45, ... }
    ↓
Step 3:  GCP Cost Collector:
         → GCP Billing Export (BigQuery) or Billing API
         → Filter by labels: service=api-gateway, env=prod
         → Returns: { service: "api-gateway", daily_cost_usd: 1.89, ... }
    ↓
Step 4:  Normalize both into unified model:
         { cloud: "aws", service: "api-gateway", date: "2026-04-15",
           compute_cost: 1.80, network_cost: 0.45, storage_cost: 0.20,
           total_cost: 2.45, currency: "USD" }
    ↓
Step 5:  Store in PostgreSQL cost_records table
    ↓
Step 6:  Dashboard displays:
         "api-gateway: AWS ₹210/day vs GCP ₹162/day (23% cheaper on GCP)"
         "Total: AWS ₹18,500/mo vs GCP ₹14,200/mo (23% savings potential)"
```

### Terraform Module Architecture

```
terraform/
├── main.tf                           # Root: selects cloud-specific module
├── variables.tf                      # Shared variables (cloud, region, env)
├── outputs.tf                        # Cluster endpoints, LB IPs
├── versions.tf                       # Provider version constraints
├── backend.tf                        # Remote state configuration
│
├── environments/                     # Environment-specific tfvars
│   ├── dev.tfvars
│   ├── staging.tfvars
│   └── prod.tfvars
│
├── modules/                          # Reusable, cloud-agnostic modules
│   ├── networking/                   # VPC/Network abstraction
│   │   ├── main.tf                   # Routes to cloud-specific module
│   │   ├── variables.tf              # cidr_block, subnet_count, etc.
│   │   ├── outputs.tf                # vpc_id, subnet_ids, etc.
│   │   ├── aws/                      # AWS-specific implementation
│   │   │   ├── main.tf               # aws_vpc, aws_subnet, aws_nat_gateway
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── gcp/                      # GCP-specific implementation
│   │       ├── main.tf               # google_compute_network, google_compute_subnetwork
│   │       ├── variables.tf
│   │       └── outputs.tf
│   │
│   ├── kubernetes/                   # K8s cluster abstraction
│   │   ├── main.tf                   # Routes to EKS or GKE module
│   │   ├── variables.tf              # cluster_name, node_count, machine_type
│   │   ├── outputs.tf                # cluster_endpoint, kubeconfig
│   │   ├── aws/                      # EKS implementation
│   │   │   ├── main.tf               # aws_eks_cluster, aws_eks_node_group
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── gcp/                      # GKE implementation
│   │       ├── main.tf               # google_container_cluster, google_container_node_pool
│   │       ├── variables.tf
│   │       └── outputs.tf
│   │
│   ├── database/                     # Managed PostgreSQL abstraction
│   │   ├── aws/                      # RDS PostgreSQL
│   │   └── gcp/                      # Cloud SQL PostgreSQL
│   │
│   ├── cache/                        # Managed Redis abstraction
│   │   ├── aws/                      # ElastiCache Redis
│   │   └── gcp/                      # Memorystore Redis
│   │
│   ├── ingress/                      # Load Balancer / Ingress abstraction
│   │   ├── aws/                      # AWS ALB Ingress Controller
│   │   └── gcp/                      # GCP Ingress (NEG)
│   │
│   ├── monitoring/                   # Prometheus + Grafana per cloud
│   │   └── main.tf                   # Helm release: kube-prometheus-stack
│   │
│   ├── dns/                          # Cloudflare DNS + traffic routing
│   │   ├── main.tf                   # cloudflare_record, cloudflare_load_balancer
│   │   └── variables.tf              # weights, health_check_path
│   │
│   └── application/                  # Helm-based app deployment
│       ├── main.tf                   # helm_release for each microservice
│       └── variables.tf              # image_tag, replicas, resources
│
└── workspaces/                       # Workspace configs
    ├── aws-dev.tfbackend
    ├── aws-staging.tfbackend
    ├── aws-prod.tfbackend
    ├── gcp-dev.tfbackend
    ├── gcp-staging.tfbackend
    └── gcp-prod.tfbackend
```

---

## 5. Low-Level Design (LLD)

### 5.1 Terraform: Cloud-Agnostic Module Pattern

```hcl
# modules/kubernetes/main.tf — The abstraction layer

variable "cloud_provider" {
  type        = string
  description = "Cloud provider: 'aws' or 'gcp'"
  validation {
    condition     = contains(["aws", "gcp"], var.cloud_provider)
    error_message = "cloud_provider must be 'aws' or 'gcp'"
  }
}

variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string; default = "1.29" }
variable "node_count" { type = number; default = 3 }
variable "node_machine_type" { type = string; default = "standard" }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

# Machine type mapping: abstract → cloud-specific
locals {
  machine_types = {
    aws = {
      small    = "t3.medium"
      standard = "t3.large"
      large    = "t3.xlarge"
    }
    gcp = {
      small    = "e2-medium"
      standard = "e2-standard-4"
      large    = "e2-standard-8"
    }
  }

  actual_machine_type = local.machine_types[var.cloud_provider][var.node_machine_type]
}

# Route to cloud-specific implementation
module "eks" {
  source = "./aws"
  count  = var.cloud_provider == "aws" ? 1 : 0

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  node_count         = var.node_count
  instance_type      = local.actual_machine_type
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
}

module "gke" {
  source = "./gcp"
  count  = var.cloud_provider == "gcp" ? 1 : 0

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  node_count         = var.node_count
  machine_type       = local.actual_machine_type
  network            = var.vpc_id
  subnetwork         = var.subnet_ids[0]
}

# Unified outputs (same interface regardless of cloud)
output "cluster_endpoint" {
  value = var.cloud_provider == "aws" ? module.eks[0].cluster_endpoint : module.gke[0].cluster_endpoint
}

output "cluster_ca_certificate" {
  value = var.cloud_provider == "aws" ? module.eks[0].cluster_ca : module.gke[0].cluster_ca
}

output "kubeconfig" {
  value     = var.cloud_provider == "aws" ? module.eks[0].kubeconfig : module.gke[0].kubeconfig
  sensitive = true
}
```

### 5.2 AWS EKS Module

```hcl
# modules/kubernetes/aws/main.tf

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_service_policy,
  ]

  tags = {
    Project     = "cloudbridge"
    ManagedBy   = "terraform"
    Cloud       = "aws"
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = var.node_count
    max_size     = var.node_count + 2
    min_size     = 1
  }

  instance_types = [var.instance_type]
  disk_size      = 50

  tags = {
    Project   = "cloudbridge"
    ManagedBy = "terraform"
  }
}

# IAM roles, security groups, OIDC provider omitted for brevity
```

### 5.3 GCP GKE Module

```hcl
# modules/kubernetes/gcp/main.tf

resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.region

  # Use separately managed node pool
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network
  subnetwork = var.subnetwork

  min_master_version = var.kubernetes_version

  # Workload Identity (GCP best practice)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Network policy
  network_policy {
    enabled = true
  }

  resource_labels = {
    project    = "cloudbridge"
    managed-by = "terraform"
    cloud      = "gcp"
  }
}

resource "google_container_node_pool" "main" {
  name       = "${var.cluster_name}-pool"
  location   = var.region
  cluster    = google_container_cluster.main.name
  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      project    = "cloudbridge"
      managed-by = "terraform"
    }
  }

  autoscaling {
    min_node_count = 1
    max_node_count = var.node_count + 2
  }
}
```

### 5.4 Cloudflare Weighted DNS

```hcl
# modules/dns/main.tf

resource "cloudflare_load_balancer_pool" "aws" {
  name = "aws-pool"

  origins {
    name    = "aws-eks-lb"
    address = var.aws_lb_ip
    enabled = true
    weight  = var.weights.aws  # 0.7 (70%)
  }

  check_regions = ["WNAM", "ENAM"]
  notification_email = var.notification_email
}

resource "cloudflare_load_balancer_pool" "gcp" {
  name = "gcp-pool"

  origins {
    name    = "gcp-gke-lb"
    address = var.gcp_lb_ip
    enabled = true
    weight  = var.weights.gcp  # 0.3 (30%)
  }

  check_regions = ["WEU", "EEU"]
}

resource "cloudflare_load_balancer_monitor" "health" {
  type           = "https"
  expected_body  = ""
  expected_codes = "200"
  method         = "GET"
  path           = "/health"
  interval       = 60
  retries        = 2
  timeout        = 5
  description    = "CloudBridge health check"
}

resource "cloudflare_load_balancer" "main" {
  zone_id          = var.cloudflare_zone_id
  name             = "app.${var.domain}"
  fallback_pool_id = cloudflare_load_balancer_pool.gcp.id  # GCP is fallback
  default_pool_ids = [
    cloudflare_load_balancer_pool.aws.id,
    cloudflare_load_balancer_pool.gcp.id,
  ]

  description = "CloudBridge multi-cloud load balancer"
  proxied     = true

  # Weighted routing: traffic split based on pool weights
  steering_policy = "random"  # Random weighted = respects origin weights
}
```

### 5.5 Root Module — The One-Variable Switch

```hcl
# main.tf — Root module

variable "cloud_provider" {
  type        = string
  description = "Deploy to 'aws' or 'gcp' (or 'both' for multi-cloud)"
  default     = "both"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "cloudflare_weights" {
  type = map(number)
  default = {
    aws = 70
    gcp = 30
  }
}

# Network
module "networking" {
  source          = "./modules/networking"
  cloud_provider  = var.cloud_provider
  cidr_block      = "10.0.0.0/16"
  environment     = var.environment
}

# Kubernetes cluster
module "kubernetes" {
  source             = "./modules/kubernetes"
  cloud_provider     = var.cloud_provider
  cluster_name       = "cloudbridge-${var.environment}"
  node_count         = var.environment == "prod" ? 3 : 2
  node_machine_type  = var.environment == "prod" ? "standard" : "small"
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.subnet_ids
}

# Managed PostgreSQL
module "database" {
  source         = "./modules/database"
  cloud_provider = var.cloud_provider
  instance_name  = "cloudbridge-${var.environment}"
  engine_version = "16"
}

# Managed Redis
module "cache" {
  source         = "./modules/cache"
  cloud_provider = var.cloud_provider
  instance_name  = "cloudbridge-${var.environment}"
}

# Application deployment (Helm)
module "application" {
  source         = "./modules/application"
  cluster_endpoint     = module.kubernetes.cluster_endpoint
  cluster_ca           = module.kubernetes.cluster_ca_certificate
  image_tag            = var.image_tag
  database_url         = module.database.connection_string
  redis_url            = module.cache.connection_string
}

# Monitoring (Prometheus + Grafana)
module "monitoring" {
  source         = "./modules/monitoring"
  cluster_endpoint = module.kubernetes.cluster_endpoint
}

# Cloudflare DNS (only when deploying 'both')
module "dns" {
  source  = "./modules/dns"
  count   = var.cloud_provider == "both" ? 1 : 0

  aws_lb_ip   = module.kubernetes_aws.lb_ip
  gcp_lb_ip   = module.kubernetes_gcp.lb_ip
  weights     = var.cloudflare_weights
  domain      = "cloudbridge.dev"
}
```

### 5.6 Project Structure (Complete)

```
cloudbridge/
├── terraform/                          # Infrastructure-as-Code
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── modules/
│   │   ├── networking/{main,variables,outputs}.tf + aws/ + gcp/
│   │   ├── kubernetes/{main,variables,outputs}.tf + aws/ + gcp/
│   │   ├── database/{main,variables,outputs}.tf + aws/ + gcp/
│   │   ├── cache/{main,variables,outputs}.tf + aws/ + gcp/
│   │   ├── ingress/{main,variables,outputs}.tf + aws/ + gcp/
│   │   ├── monitoring/main.tf
│   │   ├── dns/main.tf
│   │   └── application/main.tf
│   ├── environments/
│   │   ├── dev.tfvars
│   │   ├── staging.tfvars
│   │   └── prod.tfvars
│   └── workspaces/
│       ├── aws-prod.tfbackend
│       └── gcp-prod.tfbackend
│
├── services/                           # Spring Boot microservices
│   ├── api-gateway/
│   │   ├── src/main/java/...
│   │   ├── Dockerfile
│   │   └── pom.xml
│   ├── order-service/
│   │   ├── src/main/java/...
│   │   ├── Dockerfile
│   │   └── pom.xml
│   └── inventory-service/
│       ├── src/main/java/...
│       ├── Dockerfile
│       └── pom.xml
│
├── charts/                             # Helm charts
│   ├── api-gateway/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   ├── order-service/
│   └── inventory-service/
│
├── cost-collector/                     # Python cost aggregation
│   ├── src/
│   │   ├── main.py
│   │   ├── aws_costs.py               # AWS Cost Explorer API
│   │   ├── gcp_costs.py               # GCP Billing API
│   │   ├── normalizer.py              # Unified cost model
│   │   └── db.py                      # PostgreSQL storage
│   ├── Dockerfile
│   └── requirements.txt
│
├── dashboard/                          # Next.js cost + deployment dashboard
│   ├── src/
│   │   ├── app/
│   │   │   ├── page.tsx               # Main: cost comparison + health
│   │   │   ├── costs/page.tsx         # Detailed cost breakdown
│   │   │   ├── deployments/page.tsx   # Deployment history
│   │   │   ├── traffic/page.tsx       # Traffic split visualization
│   │   │   └── api/
│   │   │       ├── costs/route.ts
│   │   │       ├── deployments/route.ts
│   │   │       └── health/route.ts
│   │   ├── components/
│   │   │   ├── CostComparisonChart.tsx
│   │   │   ├── CloudHealthCard.tsx
│   │   │   ├── TrafficSplitGauge.tsx
│   │   │   ├── ServiceCostTable.tsx
│   │   │   └── DeploymentTimeline.tsx
│   │   └── types/index.ts
│   ├── Dockerfile
│   └── package.json
│
├── monitoring/
│   ├── grafana/
│   │   ├── multi-cloud-dashboard.json
│   │   └── cost-dashboard.json
│   └── prometheus/
│       └── federation-config.yml      # Federate both Prometheus instances
│
├── .github/workflows/
│   ├── terraform-plan.yml             # Plan on PR
│   ├── terraform-apply.yml            # Apply on merge
│   ├── build-services.yml             # Build + push Docker images
│   └── cost-collector.yml             # Daily cost collection
│
├── docker-compose.yml                 # Local development
├── Makefile                           # Convenience commands
└── README.md
```

---

## 6. Database Design & Choice

### 6.1 Comparison Matrix

| Criteria | PostgreSQL 16 | TimescaleDB | MongoDB | Cassandra | CosmosDB |
|---|---|---|---|---|---|
| **Data Model** | Relational: clouds → environments → services → costs → deployments | Time-series + relational | Document | Wide-column | Multi-model |
| **Cost Data Frequency** | Daily aggregates (~365 records/service/year). Trivial for Postgres | Designed for per-second data — overkill | Works but no JOINs for cross-cloud queries | Absurd for this volume | Overkill and cloud-locked |
| **Cross-Cloud Joins** | "AWS cost vs GCP cost for order-service" = simple JOIN | Same (is Postgres) | $lookup across collections | Not designed for analytical JOINs | Possible but complex |
| **Deployment Audit** | FK chain: deployment → environment → cloud → terraform_workspace | Same | Denormalized docs | Limited | Possible |
| **JSONB** | Store raw cloud billing API responses | Same | Native | No | Native |
| **Multi-tenancy** | Schema-per-environment or row-level security | Same | Database-per-env | Not practical | Partition keys |

### VERDICT: PostgreSQL 16

**Why:** Cost data is collected daily (365 rows per service per year), deployment records are low-frequency events (< 50/day), and the core query is relational: "Compare AWS cost vs GCP cost for order-service over 30 days" — a simple JOIN with GROUP BY. TimescaleDB's hypertables add extension complexity for daily data that PostgreSQL handles natively. MongoDB would require denormalization to compare costs across clouds.

### 6.2 Schema Design

```sql
-- Cloud providers
CREATE TABLE cloud_providers (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(10) UNIQUE NOT NULL,   -- aws, gcp
    display_name VARCHAR(50) NOT NULL,          -- Amazon Web Services, Google Cloud Platform
    region      VARCHAR(50),                    -- us-east-1, us-central1
    is_active   BOOLEAN DEFAULT TRUE
);

-- Environments (dev, staging, prod per cloud)
CREATE TABLE environments (
    id              SERIAL PRIMARY KEY,
    cloud_id        INT REFERENCES cloud_providers(id),
    name            VARCHAR(20) NOT NULL,          -- dev, staging, prod
    terraform_workspace VARCHAR(50) UNIQUE NOT NULL, -- aws-prod, gcp-dev
    cluster_endpoint VARCHAR(500),
    cluster_status  VARCHAR(20) DEFAULT 'unknown', -- healthy, degraded, unknown
    last_deploy_at  TIMESTAMP,
    created_at      TIMESTAMP DEFAULT NOW(),
    UNIQUE(cloud_id, name)
);

-- Services deployed
CREATE TABLE services (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) UNIQUE NOT NULL,   -- api-gateway, order-service
    image_repo  VARCHAR(300),                    -- dockerhub.com/org/api-gateway
    description TEXT
);

-- Cost records (daily per service per cloud)
CREATE TABLE cost_records (
    id              SERIAL PRIMARY KEY,
    cloud_id        INT REFERENCES cloud_providers(id),
    service_id      INT REFERENCES services(id),
    environment_id  INT REFERENCES environments(id),
    date            DATE NOT NULL,
    compute_cost    DECIMAL(10,4) DEFAULT 0,     -- EC2/GCE
    network_cost    DECIMAL(10,4) DEFAULT 0,     -- Data transfer
    storage_cost    DECIMAL(10,4) DEFAULT 0,     -- EBS/PD
    database_cost   DECIMAL(10,4) DEFAULT 0,     -- RDS/Cloud SQL
    cache_cost      DECIMAL(10,4) DEFAULT 0,     -- ElastiCache/Memorystore
    lb_cost         DECIMAL(10,4) DEFAULT 0,     -- ALB/GCP LB
    total_cost      DECIMAL(10,4) NOT NULL,
    currency        VARCHAR(3) DEFAULT 'USD',
    raw_response    JSONB,                        -- Raw cloud billing API response
    collected_at    TIMESTAMP DEFAULT NOW(),
    UNIQUE(cloud_id, service_id, environment_id, date)
);
CREATE INDEX idx_cost_date ON cost_records(date DESC);
CREATE INDEX idx_cost_cloud ON cost_records(cloud_id, date);
CREATE INDEX idx_cost_service ON cost_records(service_id, date);

-- Deployment records (audit trail)
CREATE TABLE deployments (
    id                  SERIAL PRIMARY KEY,
    environment_id      INT REFERENCES environments(id),
    service_id          INT REFERENCES services(id),
    image_tag           VARCHAR(100),
    commit_sha          VARCHAR(40),
    terraform_action    VARCHAR(20),                -- plan, apply, destroy
    terraform_changes   JSONB,                       -- { add: 2, change: 1, destroy: 0 }
    status              VARCHAR(20) DEFAULT 'pending', -- pending, applying, success, failed
    triggered_by        VARCHAR(100),                -- github_actions, manual
    github_pr           INT,
    github_run_id       BIGINT,
    started_at          TIMESTAMP DEFAULT NOW(),
    completed_at        TIMESTAMP,
    error_message       TEXT
);
CREATE INDEX idx_deploy_env ON deployments(environment_id, started_at DESC);

-- Traffic split configuration
CREATE TABLE traffic_config (
    id          SERIAL PRIMARY KEY,
    aws_weight  INT DEFAULT 70,                  -- 0-100
    gcp_weight  INT DEFAULT 30,                  -- 0-100
    updated_by  VARCHAR(100),
    updated_at  TIMESTAMP DEFAULT NOW(),
    CHECK (aws_weight + gcp_weight = 100)
);
```

### 6.3 Key Queries

```sql
-- 1. Cost comparison: AWS vs GCP for all services (dashboard main view)
SELECT s.name AS service,
       SUM(cr.total_cost) FILTER (WHERE cp.name = 'aws') AS aws_cost,
       SUM(cr.total_cost) FILTER (WHERE cp.name = 'gcp') AS gcp_cost,
       SUM(cr.total_cost) FILTER (WHERE cp.name = 'aws') -
       SUM(cr.total_cost) FILTER (WHERE cp.name = 'gcp') AS aws_premium
FROM cost_records cr
JOIN services s ON cr.service_id = s.id
JOIN cloud_providers cp ON cr.cloud_id = cp.id
JOIN environments e ON cr.environment_id = e.id
WHERE e.name = 'prod'
  AND cr.date > CURRENT_DATE - INTERVAL '30 days'
GROUP BY s.name
ORDER BY aws_premium DESC;

-- 2. Monthly cost trend per cloud
SELECT date_trunc('month', date) AS month,
       cp.name AS cloud,
       SUM(total_cost) AS monthly_cost
FROM cost_records cr
JOIN cloud_providers cp ON cr.cloud_id = cp.id
WHERE date > CURRENT_DATE - INTERVAL '6 months'
GROUP BY month, cp.name
ORDER BY month;

-- 3. Cost breakdown by resource type (compute vs network vs storage)
SELECT cp.name AS cloud,
       SUM(compute_cost) AS compute,
       SUM(network_cost) AS network,
       SUM(storage_cost) AS storage,
       SUM(database_cost) AS database,
       SUM(cache_cost) AS cache,
       SUM(lb_cost) AS load_balancer
FROM cost_records cr
JOIN cloud_providers cp ON cr.cloud_id = cp.id
WHERE date > CURRENT_DATE - INTERVAL '30 days'
GROUP BY cp.name;
```

---

## 7. Caching & Messaging — Redis 7

**Purpose 1 — Dashboard Cache**
```
Key: "dashboard:costs:30d"          → Cost comparison data (TTL: 1h)
Key: "dashboard:health"             → Cloud health status (TTL: 30s)
Key: "dashboard:traffic"            → Current traffic split (TTL: 30s)
```

**Purpose 2 — Terraform State Lock Coordination**
```
Key: "terraform:lock:{workspace}"   → { locked_by: "github-run-123", locked_at: ts }
Prevents two GitHub Actions runs from applying to the same workspace simultaneously.
(Note: In production, Terraform Cloud or S3 DynamoDB locking handles this.
 Redis is for the custom coordination layer in our dashboard.)
```

**Purpose 3 — Cloud API Response Cache**
```
Key: "aws:costs:{date}"            → AWS Cost Explorer response (TTL: 6h)
Key: "gcp:costs:{date}"            → GCP Billing response (TTL: 6h)
Key: "cloudflare:health:{pool}"    → Health check status (TTL: 60s)
```

**Purpose 4 — Deployment Event Queue (Redis Streams)**
```
Stream: "deployment-events"
Producer: GitHub Actions webhook → deployment started/completed/failed
Consumer: Dashboard updater → update deployment history + invalidate cache
```

**Why NOT Kafka?** Under 50 deployments per day. Kafka's 3-broker minimum for 50 events/day is absurd.

**Why NOT RabbitMQ?** Redis already handles 3 other needs. Adding RabbitMQ for one queue adds a service.

---

## 8. Design Patterns Used

### 8.1 Abstract Factory Pattern (Cloud Provider Abstraction)

The Terraform module pattern IS the Abstract Factory:

```
CloudFactory (modules/kubernetes/main.tf)
  ├── AWSFactory (modules/kubernetes/aws/) → creates EKS
  └── GCPFactory (modules/kubernetes/gcp/) → creates GKE

Same input interface → different cloud implementations → same output interface
```

This is the most important pattern in the project. Every module (networking, kubernetes, database, cache, ingress) follows this pattern. Changing `var.cloud_provider` switches the entire factory chain.

### 8.2 Strategy Pattern (Cost Collection)

```python
class CostCollector(ABC):
    @abstractmethod
    async def collect(self, date: date, services: list) -> list[CostRecord]: ...

class AWSCostCollector(CostCollector):
    async def collect(self, date, services):
        # AWS Cost Explorer API
        response = ce_client.get_cost_and_usage(
            TimePeriod={'Start': str(date), 'End': str(date + timedelta(1))},
            Granularity='DAILY',
            GroupBy=[{'Type': 'TAG', 'Key': 'Service'}],
            Metrics=['UnblendedCost']
        )
        return self._parse(response)

class GCPCostCollector(CostCollector):
    async def collect(self, date, services):
        # GCP Billing Export via BigQuery
        query = f"""
            SELECT labels.value AS service, SUM(cost) AS total
            FROM `billing_export.gcp_billing_export_v1`
            WHERE DATE(usage_start_time) = '{date}'
            GROUP BY service
        """
        return self._parse(bigquery_client.query(query))

collectors = { 'aws': AWSCostCollector(), 'gcp': GCPCostCollector() }
```

### 8.3 Facade Pattern (Unified Terraform Output)

Every cloud-specific module outputs the same interface:

```hcl
# Both AWS and GCP modules output these SAME variables:
output "cluster_endpoint" { ... }
output "cluster_ca_certificate" { ... }
output "kubeconfig" { ... }
output "lb_ip" { ... }
output "database_connection_string" { ... }
output "redis_connection_string" { ... }
```

The parent module doesn't care which cloud produced them.

### 8.4 Observer Pattern (Deployment Event Propagation)

```python
event_bus.on('deployment:started', update_dashboard_status)
event_bus.on('deployment:completed', record_in_database)
event_bus.on('deployment:completed', invalidate_cache)
event_bus.on('deployment:failed', send_slack_alert)
event_bus.on('deployment:completed', trigger_health_check)
```

### 8.5 Template Method (CI/CD Pipeline Structure)

GitHub Actions workflow defines the template; cloud-specific steps differ:

```yaml
# Template: plan → approve → apply → verify
# AWS step: terraform plan -var="cloud=aws"
# GCP step: terraform plan -var="cloud=gcp"
# Both follow the same lifecycle, different provider config
```

---

## 9. Docker & Kubernetes Deployment

### 9.1 Docker Compose (Local Dev)

```yaml
version: '3.8'

services:
  api-gateway:
    build: ./services/api-gateway
    ports: ["8080:8080"]
    environment:
      - ORDER_SERVICE_URL=http://order-service:8081
      - INVENTORY_SERVICE_URL=http://inventory-service:8082

  order-service:
    build: ./services/order-service
    ports: ["8081:8081"]
    environment:
      - DATABASE_URL=jdbc:postgresql://postgres:5432/orders
      - REDIS_URL=redis://redis:6379

  inventory-service:
    build: ./services/inventory-service
    ports: ["8082:8082"]
    environment:
      - REDIS_URL=redis://redis:6379

  dashboard:
    build: ./dashboard
    ports: ["3000:3000"]
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@postgres:5432/cloudbridge
      - REDIS_URL=redis://redis:6379

  cost-collector:
    build: ./cost-collector
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@postgres:5432/cloudbridge
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - GCP_CREDENTIALS=${GCP_CREDENTIALS}

  postgres:
    image: postgres:16-alpine
    ports: ["5432:5432"]
    environment: { POSTGRES_DB: cloudbridge, POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres }
    volumes: [postgres_data:/var/lib/postgresql/data]

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]

  grafana:
    image: grafana/grafana:latest
    ports: ["3001:3000"]
    volumes: [./monitoring/grafana:/etc/grafana/provisioning]

volumes:
  postgres_data:
```

### 9.2 Helm Values (Cloud-Agnostic)

```yaml
# charts/api-gateway/values.yaml

replicaCount: 2

image:
  repository: yourdockerhub/cloudbridge-api-gateway
  tag: latest

resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits: { cpu: 500m, memory: 512Mi }

# These are set by Terraform via Helm provider, different per cloud
env:
  ORDER_SERVICE_URL: "http://order-service:8081"
  INVENTORY_SERVICE_URL: "http://inventory-service:8082"
  CLOUD_PROVIDER: ""  # Set by Terraform: "aws" or "gcp"

# Ingress annotations differ per cloud — Terraform sets these
ingress:
  enabled: true
  className: ""  # "alb" for AWS, "gce" for GCP — set by Terraform
  annotations: {}  # Cloud-specific — set by Terraform
```

---

## 10. CI/CD Pipeline — GitHub Actions

### 10.1 Terraform Plan on PR

```yaml
# .github/workflows/terraform-plan.yml
name: Terraform Plan

on:
  pull_request:
    paths: ['terraform/**']

jobs:
  plan:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        cloud: [aws, gcp]
    
    steps:
      - uses: actions/checkout@v4
      
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.7.0" }
      
      - name: Configure cloud credentials
        run: |
          if [ "${{ matrix.cloud }}" == "aws" ]; then
            aws configure set aws_access_key_id ${{ secrets.AWS_ACCESS_KEY_ID }}
            aws configure set aws_secret_access_key ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          else
            echo '${{ secrets.GCP_SA_KEY }}' > gcp-key.json
            export GOOGLE_APPLICATION_CREDENTIALS=gcp-key.json
          fi
      
      - name: Terraform Init
        run: |
          cd terraform
          terraform init -backend-config="workspaces/${{ matrix.cloud }}-prod.tfbackend"
      
      - name: Terraform Plan
        id: plan
        run: |
          cd terraform
          terraform plan -var="cloud_provider=${{ matrix.cloud }}" \
                         -var-file="environments/prod.tfvars" \
                         -no-color -out=tfplan 2>&1 | tee plan-output.txt
      
      - name: Comment PR with Plan
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('terraform/plan-output.txt', 'utf8');
            const cloud = '${{ matrix.cloud }}'.toUpperCase();
            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: `## ☁️ Terraform Plan — ${cloud}\n\`\`\`\n${plan.slice(-3000)}\n\`\`\``
            });
```

### 10.2 Terraform Apply on Merge

```yaml
# .github/workflows/terraform-apply.yml
name: Terraform Apply

on:
  push:
    branches: [main]
    paths: ['terraform/**']

jobs:
  apply:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        cloud: [aws, gcp]
    environment: production  # Requires manual approval
    
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      
      - name: Configure credentials
        run: |
          # Same credential setup as plan workflow

      - name: Terraform Apply
        run: |
          cd terraform
          terraform init -backend-config="workspaces/${{ matrix.cloud }}-prod.tfbackend"
          terraform apply -var="cloud_provider=${{ matrix.cloud }}" \
                          -var-file="environments/prod.tfvars" \
                          -auto-approve
      
      - name: Post deployment event
        run: |
          curl -X POST https://dashboard.cloudbridge.dev/api/deployments \
            -H "Authorization: Bearer ${{ secrets.DASHBOARD_TOKEN }}" \
            -d '{
              "cloud": "${{ matrix.cloud }}",
              "status": "success",
              "commit_sha": "${{ github.sha }}",
              "github_run_id": ${{ github.run_id }}
            }'
```

### 10.3 Build + Deploy Services

```yaml
# .github/workflows/build-services.yml
name: Build & Deploy Services

on:
  push:
    branches: [main]
    paths: ['services/**']

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [api-gateway, order-service, inventory-service]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      - run: |
          docker build -t ${{ secrets.DOCKER_USERNAME }}/cloudbridge-${{ matrix.service }}:${{ github.sha }} \
                        ./services/${{ matrix.service }}
          docker push ${{ secrets.DOCKER_USERNAME }}/cloudbridge-${{ matrix.service }}:${{ github.sha }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    strategy:
      matrix:
        cloud: [aws, gcp]
    steps:
      - uses: actions/checkout@v4
      - name: Configure kubectl
        run: |
          # Get kubeconfig from Terraform output or cloud CLI
          if [ "${{ matrix.cloud }}" == "aws" ]; then
            aws eks update-kubeconfig --name cloudbridge-prod
          else
            gcloud container clusters get-credentials cloudbridge-prod
          fi
      - name: Helm upgrade
        run: |
          for service in api-gateway order-service inventory-service; do
            helm upgrade --install $service ./charts/$service \
              --set image.tag=${{ github.sha }} \
              --set env.CLOUD_PROVIDER=${{ matrix.cloud }}
          done
```

---

## 11. Monitoring — The "Scaling Decision" to Document

### Grafana Multi-Cloud Dashboard (4 Panels)

**Panel 1: Cost Comparison Bar Chart**
- Side-by-side: AWS vs GCP monthly cost per service
- "api-gateway: AWS ₹6,200 vs GCP ₹4,800 (23% cheaper on GCP)"

**Panel 2: Traffic Split Gauge**
- Dual gauges showing current Cloudflare weights
- "AWS: 70% | GCP: 30%"

**Panel 3: Cluster Health**
- Two health cards: AWS EKS (green/red) + GCP GKE (green/red)
- Pod count, node count, CPU/memory utilization per cloud

**Panel 4: Deployment Timeline**
- Combined timeline showing deployments to both clouds
- "14:30 — Deploy v2.3.1 to AWS ✅ | 14:31 — Deploy v2.3.1 to GCP ✅"

### The "Scaling Decision" to Document

> **Scaling Decision: Terraform Workspaces over Separate Terraform Codebases**
>
> **Problem:** Managing infrastructure for 2 clouds × 3 environments = 6 deployment targets. How do I organize the Terraform code?
>
> **Option A — Separate codebases:** One Terraform repo for AWS, another for GCP. Pros: complete isolation. Cons: code duplication, drift between clouds, double the PR reviews, double the CI/CD pipelines. When I add a new service, I modify TWO repos.
>
> **Option B — Terraform workspaces:** One codebase with cloud-agnostic modules. `var.cloud_provider` selects the implementation. Workspaces separate state: `aws-prod`, `gcp-prod`, `aws-dev`, `gcp-dev`. Pros: single source of truth, one PR for both clouds, shared module code. Cons: more complex module design (conditional resources).
>
> **Option C — Terragrunt:** Wrapper that manages workspaces and DRY configurations. Pros: cleaner than raw workspaces for complex setups. Cons: additional tool dependency, learning curve for contributors.
>
> **Decision:** Option B (Terraform workspaces with cloud-agnostic modules). The module abstraction pattern (same variables → cloud-specific implementations → same outputs) keeps the codebase DRY. A single PR shows changes to BOTH clouds side-by-side. The `count` meta-argument conditionally creates cloud-specific resources. This is the pattern used by companies like Gruntwork and HashiCorp's reference architectures.
>
> **When I'd switch to Terragrunt:** If we added a third cloud (Azure) or exceeded 10 environments, Terragrunt's `terragrunt.hcl` inheritance model would reduce boilerplate. For 2 clouds × 3 environments, raw workspaces are simpler.

---

## 12. Interview Prep — Top Questions & Answers

**Q1: "Walk me through the architecture."**

> "The same Spring Boot microservices run on both AWS EKS and GCP GKE, deployed from one Terraform codebase. Each cloud has its own VPC/network, Kubernetes cluster, managed PostgreSQL, managed Redis, and load balancer — all created by cloud-agnostic Terraform modules. The `var.cloud_provider` variable selects the implementation: 'aws' creates EKS + RDS + ElastiCache, 'gcp' creates GKE + Cloud SQL + Memorystore. Docker images are built once and pushed to DockerHub — both clouds pull the same images. Cloudflare sits in front as a global load balancer with weighted DNS: 70% routes to AWS, 30% to GCP. Health checks ensure automatic failover. A cost comparison dashboard pulls data from AWS Cost Explorer and GCP Billing APIs, normalizes it into PostgreSQL, and shows per-service spend across both clouds."

**Q2: "What does 'no vendor lock-in' mean practically?"**

> "Three things. First, infrastructure code: changing `var.cloud_provider` from 'aws' to 'gcp' deploys identical infrastructure to a different cloud. Second, application code: the Spring Boot services use standard Kubernetes APIs (Deployment, Service, Ingress) — no AWS-specific or GCP-specific SDKs. Database connections use standard JDBC strings; Redis uses standard Redis protocol. Third, traffic routing: changing Cloudflare weights from `{aws: 70, gcp: 30}` to `{aws: 0, gcp: 100}` shifts all production traffic between clouds in under 60 seconds. The entire migration is one variable change and one `terraform apply`."

**Q3: "How do Terraform workspaces help here?"**

> "Workspaces separate state files for the same Terraform configuration. I have 6 workspaces: `aws-dev`, `aws-staging`, `aws-prod`, `gcp-dev`, `gcp-staging`, `gcp-prod`. Each workspace maintains its own state — so applying to `aws-prod` doesn't affect `gcp-prod`. The state is stored remotely: AWS workspaces use S3 + DynamoDB for locking, GCP workspaces use GCS. In CI/CD, the GitHub Actions matrix strategy runs `terraform plan` for both clouds in parallel, posts both diffs to the PR, and on merge, applies to both clouds with separate workspace states."

**Q4: "How does the cost comparison work?"**

> "A daily Python cron job queries both AWS Cost Explorer API and GCP Billing BigQuery export. Both APIs return per-service cost data — AWS uses resource tags, GCP uses labels. The normalizer converts both into a unified model: cloud, service, date, compute_cost, network_cost, storage_cost, total_cost. This goes into PostgreSQL. The Next.js dashboard queries this table and shows side-by-side comparisons. In our demo, the same 3-service application costs ₹18,500/month on AWS versus ₹14,200/month on GCP — a 23% difference driven primarily by compute and data transfer pricing."

**Q5: "Why PostgreSQL and not TimescaleDB or MongoDB?"**

> "Cost data is collected daily — 365 records per service per year. That's trivially small for PostgreSQL. The core query is relational: 'Compare AWS cost vs GCP cost for order-service over 30 days' — a simple JOIN with GROUP BY that returns in under 50 milliseconds. TimescaleDB's hypertables and continuous aggregates add extension complexity for daily data that doesn't need time-series optimization. MongoDB would require $lookup pipelines for cross-cloud comparison queries that PostgreSQL handles with native JOINs."

**Q6: "How do you handle Terraform state safely?"**

> "Remote state with locking. AWS workspaces store state in S3 with DynamoDB table for locking — if two developers run `terraform apply` simultaneously, the second gets a lock error. GCP workspaces store state in GCS with built-in locking. State files are encrypted at rest (S3 SSE, GCS encryption). Sensitive values in state (database passwords, API keys) are marked `sensitive = true` in outputs, which prevents them from appearing in CLI output and plan diffs. In CI/CD, only the main branch can apply — PR branches only run `terraform plan`."

**Q7: "What's the Cloudflare traffic split and failover?"**

> "Cloudflare Load Balancing with weighted pools. The AWS pool has weight 0.7 (70%), GCP pool has weight 0.3 (30%). Cloudflare's health monitor pings `/health` on both endpoints every 60 seconds. If AWS health check fails 2 consecutive times, Cloudflare automatically routes 100% to GCP — zero manual intervention. Recovery is automatic too: when AWS health check passes again, traffic gradually returns to the 70/30 split. The weights are managed by Terraform via the Cloudflare provider, so changing the split is a code change with PR review."

**Q8: "How would you add Azure as a third cloud?"**

> "Add a `modules/kubernetes/azure/` directory with AKS (Azure Kubernetes Service) Terraform resources. Add `modules/networking/azure/` with Azure VNet. Add 'azure' to the `cloud_provider` validation list. Create `azure-prod.tfbackend` workspace config. Add Azure pool to Cloudflare load balancer with weight adjustments (e.g., 50/30/20). Add `AzureCostCollector` to the cost collector with Azure Cost Management API. The module abstraction pattern means existing AWS and GCP code doesn't change — we just add a new implementation of the same interface. This extensibility is the design's strength."

**Q9: "What about data consistency between clouds?"**

> "Each cloud has its own PostgreSQL database — orders created on AWS are stored in RDS, orders on GCP in Cloud SQL. For this demo, we don't synchronize data between clouds — each handles its share of traffic independently. In production, you'd need either cross-cloud database replication (CockroachDB, Spanner) or an eventual consistency model where a message queue synchronizes changes. I chose NOT to add this complexity because it's a separate problem from the deployment automation this project demonstrates. But I can discuss the trade-offs: CockroachDB gives multi-cloud SQL, Spanner gives global consistency but is GCP-locked, and CDC (Change Data Capture) with Kafka gives eventual consistency."

**Q10: "Describe the demo flow."**

> "I open the dashboard — it shows both clouds healthy, traffic split 70/30. I show the cost comparison: AWS ₹18,500/month, GCP ₹14,200/month. I open a PR changing one Terraform variable: `node_count = 4`. GitHub Actions posts TWO plan diffs — one for AWS, one for GCP. I merge — both clouds scale to 4 nodes. Then the dramatic moment: I change `cloudflare_weights` to `{aws: 0, gcp: 100}`. Within 60 seconds, the dashboard shows all traffic on GCP. I open the app — it works. I switch back to 70/30. 'I just migrated production between clouds by changing one variable. That's zero vendor lock-in.'"

---

## 13. Deployment Checklist

- [ ] Terraform modules create VPC + K8s + DB + Cache on AWS
- [ ] Same modules create identical infra on GCP
- [ ] 3 Spring Boot services running on both EKS and GKE
- [ ] Cloudflare weighted DNS: 70/30 split working
- [ ] Health checks: take down one cloud → traffic fails over
- [ ] GitHub Actions: plan on PR, apply on merge, per-cloud
- [ ] Cost collector: daily AWS + GCP cost data in PostgreSQL
- [ ] Dashboard: cost comparison, traffic split, deployment timeline
- [ ] Grafana: multi-cloud metrics from both Prometheus instances
- [ ] Docker Compose for local development
- [ ] README: architecture diagram, module docs, setup guide
- [ ] Demo video: one-variable cloud switch
- [ ] Scaling decision documented
- [ ] Cost numbers: "AWS ₹18,500 vs GCP ₹14,200" with calculation

### Cost Estimate (for the project itself)

| Service | Provider | Cost |
|---|---|---|
| AWS EKS (2 t3.medium nodes, dev) | AWS Free Tier + ~$60/mo | ~₹5,000/mo |
| GCP GKE (2 e2-medium nodes, dev) | GCP Free Tier + ~$50/mo | ~₹4,200/mo |
| Cloudflare (free plan + LB) | Cloudflare | Free tier (LB: $5/mo) |
| DockerHub | Docker | Free (public images) |
| Dashboard hosting (Railway) | Railway | ~$5/mo |
| **Total** | | **~₹10,000/mo** (with free tier credits: ~₹2,000/mo) |

**Cost optimization tip:** Use AWS Free Tier (750 hrs/mo t3.micro) + GCP Free Tier ($300 credit) to keep demo costs minimal. Destroy infrastructure when not demoing (`terraform destroy`).

---

## Final Word — Why This Project Wins DevOps Interviews

CloudBridge demonstrates the single most in-demand DevOps skill in Bangalore 2026: **multi-cloud Terraform automation**.

**The maturity hierarchy:**
1. **Level 1 (most freshers):** "I deployed to AWS using the console" → basic
2. **Level 2 (good freshers):** "I wrote Terraform to deploy to AWS" → intermediate
3. **Level 3 (you):** "I wrote Terraform that deploys to BOTH AWS and GCP from one codebase, with traffic splitting and cost comparison" → senior-level

**What makes this uniquely valuable:**
- **Multi-cloud Terraform** is on EVERY senior DevOps JD in India — you're demonstrating it as a junior
- **Cloud provider abstraction** — the module pattern IS the answer to "how do you avoid vendor lock-in?"
- **Real cost data** — "AWS costs 23% more than GCP for the same workload" is a business insight, not just tech
- **Traffic management** — Cloudflare weighted DNS with failover is production-grade
- **GitOps** — Terraform plans on PRs, applies on merge, manual approval for prod

**The sentence that wins:** "I can deploy to a different cloud by changing one Terraform variable. The same pipeline runs for both — no vendor lock-in by design. And the cost dashboard showed GCP was 23% cheaper for our workload."

Every company running cloud infrastructure wants this capability. You built it as a fresher. That's the differentiator.

---

*Document prepared as a complete implementation guide for CloudBridge — Multi-Cloud Deployment Automation with Terraform (2026)*
