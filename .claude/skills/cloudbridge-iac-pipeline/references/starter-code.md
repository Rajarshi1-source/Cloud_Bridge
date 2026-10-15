# CloudBridge IaC Pipeline — Starter Code

## Contents
1. CI identities (Terraform, `global/00-ci-identity`)
2. `_terraform-stack.yml` (reusable)
3. `iac-pr.yml` (PR fan-out + sticky comment)
4. `iac-apply.yml` (ordered apply on merge)
5. `iac-engines.yml` (Terraform + OpenTofu)
6. `drift.yml`, `ttl-reaper.yml`, `ephemeral-up.yml`
7. `tools/affected_stacks.py`
8. Conftest policies

---

## 1. CI identities

```hcl
# infra/live/global/00-ci-identity/aws.tf
data "tls_certificate" "gh" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.gh.certificates[0].sha1_fingerprint]
}

locals {
  repo = "${var.github_owner}/cloudbridge"
  aws_roles = {
    "cb-plan-aws"       = "repo:${local.repo}:pull_request"
    "cb-apply-aws-prod" = "repo:${local.repo}:environment:aws-prod"
    "cb-apply-aws-dev"  = "repo:${local.repo}:environment:aws-dev"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.aws_roles
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "ci" {
  for_each             = local.aws_roles
  name                 = each.key
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.ci["cb-plan-aws"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "state" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::cb-tfstate-aws"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::cb-tfstate-aws/*"]   # PutObject/DeleteObject needed for .tflock files
  }
}

resource "aws_iam_role_policy" "state" {
  for_each = local.aws_roles
  role     = aws_iam_role.ci[each.key].id
  policy   = data.aws_iam_policy_document.state.json
}
# Apply roles additionally get a scoped policy (tag-conditioned on cb-cell) — write it per environment.
```

```hcl
# infra/live/global/00-ci-identity/gcp.tf
resource "google_iam_workload_identity_pool" "gh" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "github"
}

resource "google_iam_workload_identity_pool_provider" "gh" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.gh.workload_identity_pool_id
  workload_identity_pool_provider_id = "cloudbridge"
  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.repository"   = "assertion.repository"
    "attribute.environment"  = "assertion.environment"
    "attribute.event_name"   = "assertion.event_name"
  }
  attribute_condition = "assertion.repository == '${var.github_owner}/cloudbridge'"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  gcp_sas = {
    "cb-plan-gcp"       = "attribute.event_name/pull_request"
    "cb-apply-gcp-prod" = "attribute.environment/gcp-prod"
    "cb-apply-traffic"  = "attribute.environment/traffic-prod"
  }
}

resource "google_service_account" "ci" {
  for_each   = local.gcp_sas
  project    = var.gcp_project_id
  account_id = each.key
}

resource "google_service_account_iam_member" "wif" {
  for_each           = local.gcp_sas
  service_account_id = google_service_account.ci[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gh.name}/${each.value}"
}

resource "google_project_iam_member" "plan_viewer" {
  project = var.gcp_project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.ci["cb-plan-gcp"].email}"
}
```

## 1b. Week 3: the ephemeral identities (implemented)

Built first because `ttl-reaper.yml` can't run without a cloud identity. `aws_iam_openid_connect_provider` no longer needs a thumbprint (AWS trusts GitHub's CA); the trust policy is `jsonencode`d so the stack test can assert the `sub` condition through mocks.

```hcl
# infra/live/global/00-ci-identity/aws.tf
# GitHub Actions → AWS without stored keys. The trust is bound to one repository AND one GitHub
# environment: only a job running inside environment "ephemeral" gets a token with this `sub`.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  ephemeral_sub = "repo:${var.github_repository}:environment:ephemeral"
}

resource "aws_iam_role" "ephemeral" {
  name                 = "cb-ephemeral-aws"
  description          = "ephemeral-up.yml and ttl-reaper.yml: create and destroy the aws-dev cell"
  max_session_duration = 7200
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.ephemeral_sub
        }
      }
    }]
  })
}

# Everything except IAM; IAM only for cb-* names (the cell's cluster, node and add-on roles).
resource "aws_iam_role_policy_attachment" "ephemeral_power_user" {
  role       = aws_iam_role.ephemeral.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "ephemeral_iam_scoped" {
  name = "cb-iam-and-state"
  role = aws_iam_role.ephemeral.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CellRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:ListInstanceProfilesForRole", "iam:TagInstanceProfile",
        ]
        Resource = [
          "arn:aws:iam::*:role/cb-*",
          "arn:aws:iam::*:instance-profile/cb-*",
        ]
      },
      {
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "elasticloadbalancing.amazonaws.com", "autoscaling.amazonaws.com"]
          }
        }
      },
      {
        Sid      = "StateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.aws_state_bucket}"
      },
      {
        Sid      = "DevState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.aws_state_bucket}/aws-dev/*" # dev state and its .tflock only
      },
    ]
  })
}
```

```hcl
# infra/live/global/00-ci-identity/gcp.tf
# GitHub Actions → GCP through Workload Identity Federation. The provider admits tokens from one
# repository only; the service account admits only the "ephemeral" environment of that repository.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "cloudbridge"
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.environment" = "assertion.environment"
  }
  attribute_condition = "assertion.repository == '${var.github_repository}'"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ephemeral" {
  project      = var.gcp_project_id
  account_id   = "cb-ephemeral-gcp"
  display_name = "ephemeral-up.yml and ttl-reaper.yml (gcp-dev cell)"
}

resource "google_service_account_iam_member" "ephemeral_wif" {
  service_account_id = google_service_account.ephemeral.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/ephemeral"
}

# What the gcp-dev cell creates: network + NAT, GKE, its node service account and that account's
# project roles, the Artifact Registry remote repository (and its read of the pull token).
# projectIamAdmin is the broad one: GKE's node account needs project-level role grants.
resource "google_project_iam_member" "ephemeral" {
  for_each = toset([
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
  ])
  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ephemeral.email}"
}

# Listing objects is a bucket-level permission, which an object-name condition never matches; this
# legacy role grants list (and bucket metadata) without reading any object, e.g. the origin key's state.
resource "google_storage_bucket_iam_member" "ephemeral_state_list" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.ephemeral.email}"
}

resource "google_storage_bucket_iam_member" "ephemeral_state" {
  bucket = var.gcp_state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ephemeral.email}"
  condition {
    title      = "gcp-dev-state-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.gcp_state_bucket}/objects/gcp-dev/\")"
  }
}
```

## 2. `_terraform-stack.yml`

```yaml
name: terraform-stack
on:
  workflow_call:
    inputs:
      stack:
        type: string
        required: true
      cloud:
        type: string
        required: true
      mode:
        type: string
        required: true
      env:
        type: string
        required: false
        default: ""
    outputs:
      verdict:
        value: ${{ jobs.run.outputs.verdict }}

permissions:
  contents: read
  id-token: write

jobs:
  run:
    runs-on: ubuntu-24.04
    environment: ${{ inputs.mode == 'apply' && inputs.env || null }}
    concurrency:
      group: tf-${{ inputs.stack }}
      cancel-in-progress: false
    outputs:
      verdict: ${{ steps.risk.outputs.verdict }}
    defaults:
      run:
        working-directory: ${{ inputs.stack }}
    steps:
      - uses: actions/checkout@<sha>
      - uses: hashicorp/setup-terraform@<sha>
        with:
          terraform_version: "1.15.x"
          terraform_wrapper: false

      - name: AWS credentials
        if: inputs.cloud == 'aws'
        uses: aws-actions/configure-aws-credentials@<sha>
        with:
          role-to-assume: ${{ inputs.mode == 'apply' && vars.AWS_APPLY_ROLE || vars.AWS_PLAN_ROLE }}   # AWS_APPLY_ROLE is an environment-scoped variable
          aws-region: ap-south-1

      - name: GCP credentials
        if: inputs.cloud == 'gcp' || inputs.cloud == 'global'
        uses: google-github-actions/auth@<sha>
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ inputs.mode == 'apply' && vars.GCP_APPLY_SA || vars.GCP_PLAN_SA }}        # environment-scoped in apply mode

      - run: terraform init -input=false -lockfile=readonly
      - run: terraform plan -input=false -lock-timeout=5m -out=tfplan
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      - run: |
          terraform show -json tfplan > plan.json
          echo "### Plan for \`${{ inputs.stack }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "sha256: \`$(sha256sum plan.json | cut -d' ' -f1)\`" >> "$GITHUB_STEP_SUMMARY"
          terraform show -no-color tfplan | tail -n 60 | sed 's/^/    /' >> "$GITHUB_STEP_SUMMARY"

      - if: inputs.mode == 'plan'
        uses: actions/download-artifact@<sha>
        with:
          name: affected
          path: ${{ github.workspace }}

      - id: risk
        if: inputs.mode == 'plan'
        run: |
          python3 "$GITHUB_WORKSPACE/control-plane/plan-risk/cli.py" plan.json \
            --stack "${{ inputs.stack }}" --affected "$GITHUB_WORKSPACE/affected.json" --out risk.json
          echo "verdict=$(jq -r .verdict risk.json)" >> "$GITHUB_OUTPUT"

      - if: inputs.mode == 'plan'
        run: conftest test plan.json -p "$GITHUB_WORKSPACE/infra/policy" --output json > conftest.json || true

      - if: inputs.mode == 'plan'
        run: infracost diff --path plan.json --format json --out-file infracost.json
        env:
          INFRACOST_API_KEY: ${{ secrets.INFRACOST_API_KEY }}

      - if: inputs.mode == 'plan'
        uses: actions/upload-artifact@<sha>
        with:
          name: plan-${{ hashFiles(format('{0}/plan.json', inputs.stack)) }}
          path: |
            ${{ inputs.stack }}/risk.json
            ${{ inputs.stack }}/conftest.json
            ${{ inputs.stack }}/infracost.json
          retention-days: 1

      - name: Apply exactly the reviewed plan
        if: inputs.mode == 'apply'
        run: terraform apply -input=false tfplan
```
Approval semantics: with `environment:` on the job, GitHub pauses *before* the job starts, so in this single-job form the reviewer approves on the basis of the PR comment (the plan from `iac-pr.yml`) and the job then re-plans and applies its own saved plan. If state moved between the PR plan and the apply plan, the step summary shows a different plan hash — compare it. For the strict form (reviewer sees *this* plan before apply), split into a `plan` job without environment that uploads `tfplan` encrypted with `age` (key in a repo secret, retention 1 day) and an `apply` job in the environment that downloads, decrypts and runs `terraform apply tfplan`. The SKILL.md "apply on merge" flow describes the strict form; start with the single-job form and upgrade once it works.

## 3. `iac-pr.yml`

```yaml
name: iac-pr
on:
  pull_request:
    paths: ["infra/**"]

permissions:
  contents: read
  id-token: write
  pull-requests: write

jobs:
  detect:
    runs-on: ubuntu-24.04
    outputs:
      stacks: ${{ steps.a.outputs.stacks }}
    steps:
      - uses: actions/checkout@<sha>
        with:
          fetch-depth: 0
      - id: a
        run: |
          python3 tools/affected_stacks.py --base origin/${{ github.base_ref }} > affected.json
          echo "stacks=$(jq -c '.stacks' affected.json)" >> "$GITHUB_OUTPUT"
      - uses: actions/upload-artifact@<sha>
        with:
          name: affected
          path: affected.json

  static:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: hashicorp/setup-terraform@<sha>
        with:
          terraform_version: "1.15.x"
      - run: terraform fmt -check -recursive infra
      - uses: terraform-linters/setup-tflint@<sha>
      - run: tflint --recursive --chdir infra
      - name: Trivy IaC
        uses: aquasecurity/trivy-action@<sha>
        with:
          scan-type: config
          scan-ref: infra
          severity: HIGH,CRITICAL
          exit-code: "1"

  plan:
    needs: detect
    if: needs.detect.outputs.stacks != '[]'
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJson(needs.detect.outputs.stacks) }}
    uses: ./.github/workflows/_terraform-stack.yml
    with:
      stack: ${{ matrix.path }}
      cloud: ${{ matrix.cloud }}
      mode: plan
    secrets: inherit

  comment:
    needs: [detect, plan]
    if: always() && needs.detect.outputs.stacks != '[]'
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/download-artifact@<sha>
        with:
          path: artifacts
      - run: python3 tools/render_pr_comment.py artifacts > comment.md
      - uses: marocchino/sticky-pull-request-comment@<sha>
        with:
          header: cloudbridge-iac
          path: comment.md
      - name: Record plan-risk results (and any override) for audit
        env:
          LABELLED: ${{ contains(github.event.pull_request.labels.*.name, 'allow-destructive') }}
        run: |
          for f in artifacts/plan-*/risk.json; do
            jq -c --arg pr "${{ github.event.pull_request.number }}" --arg by "${{ github.actor }}" --argjson ov "$LABELLED" \
              '{pr_number: ($pr|tonumber), stack, verdict, findings, overridden: ($ov and .verdict == "block"), approver: $by}' "$f" \
            | curl -fsS -X POST "${{ vars.CB_CP_API }}/plan-risk-reports" -H "Authorization: Bearer ${{ secrets.CB_CP_TOKEN }}" \
                -H 'Content-Type: application/json' --data @- || echo "::warning::could not record plan-risk report"
          done
      - name: Enforce plan-risk
        run: |
          if grep -q '"verdict": "block"' -r artifacts && \
             ! jq -e '.pull_request.labels[] | select(.name=="allow-destructive")' "$GITHUB_EVENT_PATH" >/dev/null; then
            echo "::error::plan-risk BLOCK — add the allow-destructive label after review"; exit 1
          fi
```

## 4. `iac-apply.yml`

```yaml
name: iac-apply
on:
  push:
    branches: [main]
    paths: ["infra/**"]

permissions:
  contents: read
  id-token: write

jobs:
  detect:
    runs-on: ubuntu-24.04
    outputs:
      layers: ${{ steps.a.outputs.layers }}
    steps:
      - uses: actions/checkout@<sha>
        with:
          fetch-depth: 2
      - id: a
        run: echo "layers=$(python3 tools/affected_stacks.py --base HEAD~1 --ordered | jq -c '.layers')" >> "$GITHUB_OUTPUT"

  foundation:
    needs: detect
    if: fromJson(needs.detect.outputs.layers).foundation[0] != null
    strategy:
      max-parallel: 1          # gcp before aws: smaller cell first, like the release ring
      matrix:
        include: ${{ fromJson(needs.detect.outputs.layers).foundation }}
    uses: ./.github/workflows/_terraform-stack.yml
    with:
      stack: ${{ matrix.path }}
      cloud: ${{ matrix.cloud }}
      mode: apply
      env: ${{ matrix.env }}
    secrets: inherit

  bootstrap:
    needs: [detect, foundation]
    if: always() && !failure() && fromJson(needs.detect.outputs.layers).bootstrap[0] != null
    strategy:
      max-parallel: 1
      matrix:
        include: ${{ fromJson(needs.detect.outputs.layers).bootstrap }}
    uses: ./.github/workflows/_terraform-stack.yml
    with:
      stack: ${{ matrix.path }}
      cloud: ${{ matrix.cloud }}
      mode: apply
      env: ${{ matrix.env }}
    secrets: inherit

  traffic:
    needs: [detect, bootstrap]
    if: always() && !failure() && fromJson(needs.detect.outputs.layers).traffic[0] != null
    uses: ./.github/workflows/_terraform-stack.yml
    with:
      stack: infra/live/global/30-traffic
      cloud: global
      mode: apply
      env: traffic-prod
    secrets: inherit
```

## 5. `iac-engines.yml`

```yaml
name: iac-engines
on:
  pull_request:
    paths: ["infra/modules/**"]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        engine: [terraform, tofu]
    steps:
      - uses: actions/checkout@<sha>
      - if: matrix.engine == 'terraform'
        uses: hashicorp/setup-terraform@<sha>
        with:
          terraform_version: "1.15.x"
      - if: matrix.engine == 'tofu'
        uses: opentofu/setup-opentofu@<sha>
        with:
          tofu_version: "1.12.x"
      - working-directory: infra/modules/cell
        run: |
          ${{ matrix.engine }} init -backend=false -input=false
          ${{ matrix.engine }} validate
          ${{ matrix.engine }} test
```

## 6. Scheduled workflows

```yaml
# .github/workflows/drift.yml
name: drift
on:
  schedule:
    - cron: "0 21 * * *"        # 02:30 IST
  workflow_dispatch: {}
permissions:
  contents: read
  id-token: write
  issues: write
jobs:
  plan:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        include:
          - { path: infra/live/aws-prod/10-foundation, cloud: aws }
          - { path: infra/live/aws-prod/20-bootstrap, cloud: aws }
          - { path: infra/live/gcp-prod/10-foundation, cloud: gcp }
          - { path: infra/live/gcp-prod/20-bootstrap, cloud: gcp }
          - { path: infra/live/global/30-traffic, cloud: global }
    steps:
      - uses: actions/checkout@<sha>
      - uses: hashicorp/setup-terraform@<sha>
        with:
          terraform_version: "1.15.x"
          terraform_wrapper: false
      - if: matrix.cloud == 'aws'
        uses: aws-actions/configure-aws-credentials@<sha>
        with:
          role-to-assume: ${{ vars.AWS_DRIFT_ROLE }}
          aws-region: ap-south-1
      - if: matrix.cloud != 'aws'
        uses: google-github-actions/auth@<sha>
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_PLAN_SA }}
      - id: p
        working-directory: ${{ matrix.path }}
        run: |
          terraform init -input=false -lockfile=readonly
          set +e
          terraform plan -input=false -detailed-exitcode -lock=false -no-color > plan.txt
          code=$?
          echo "code=$code" >> "$GITHUB_OUTPUT"
          [ $code -eq 1 ] && exit 1 || exit 0
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_READ_TOKEN }}
      - if: steps.p.outputs.code == '2'
        working-directory: ${{ matrix.path }}
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          grep -E '^\s*[#~+-] ' plan.txt | head -n 80 > summary.txt
          gh issue create --title "drift: ${{ matrix.path }} ($(date -u +%F))" --label drift \
            --body "Nightly plan found changes outside Terraform:\n\n\`\`\`\n$(cat summary.txt)\n\`\`\`"
```
`-lock=false` on the read-only drift plan avoids contending with a real apply; `AWS_DRIFT_ROLE` = the plan role trusted for `ref:refs/heads/main` scheduled runs (add that `sub` to the plan role's trust list).

Implemented in Week 3 (actionlint-clean, SHAs resolved 16 Oct 2026). The reaper reads the expiry from state instead of searching tags, and shares its logic with `make reap`:

```yaml
# .github/workflows/ttl-reaper.yml
# Hourly: destroy ephemeral cells whose cb-expires-at has passed. Reads the expiry from each dev
# stack's state (tools/dev/reap-expired.sh, the same script `make reap` runs), so a cell brought up
# from a laptop is reaped too. Only *-dev stacks are considered; prod never carries an expiry.
# Runs in environment "ephemeral" (same OIDC identities as ephemeral-up.yml). That environment must
# have no required reviewers, or the reaper would wait for an approval that never comes.
name: ttl-reaper

on:
  schedule:
    - cron: "17 * * * *"
  workflow_dispatch: {}

permissions:
  contents: read

jobs:
  reap:
    strategy:
      fail-fast: false
      matrix:
        cloud: [aws, gcp]
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    environment: ephemeral
    concurrency:
      group: ephemeral-${{ matrix.cloud }} # shared with ephemeral-up.yml: never reap mid-apply
      cancel-in-progress: false
    permissions:
      contents: read
      id-token: write
    steps:
      - name: Skip a cloud whose CI identity isn't configured yet
        id: cfg
        env:
          CLOUD: ${{ matrix.cloud }}
          AWS_ROLE: ${{ vars.AWS_EPHEMERAL_ROLE }}
          GCP_SA: ${{ vars.GCP_EPHEMERAL_SA }}
        run: |
          if { [ "$CLOUD" = aws ] && [ -n "$AWS_ROLE" ]; } || { [ "$CLOUD" = gcp ] && [ -n "$GCP_SA" ]; }; then
            echo "ready=true" >> "$GITHUB_OUTPUT"
          else
            echo "::notice::No CI identity for $CLOUD yet (infra/live/global/00-ci-identity); nothing reaped there. Use 'make reap' meanwhile."
            echo "ready=false" >> "$GITHUB_OUTPUT"
          fi

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        if: steps.cfg.outputs.ready == 'true'
        with:
          persist-credentials: false

      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        if: steps.cfg.outputs.ready == 'true'
        with:
          terraform_version: 1.15.9
          terraform_wrapper: false

      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        if: steps.cfg.outputs.ready == 'true' && matrix.cloud == 'aws'
        with:
          role-to-assume: ${{ vars.AWS_EPHEMERAL_ROLE }}
          aws-region: ap-south-1

      - uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093 # v3.0.0
        if: steps.cfg.outputs.ready == 'true' && matrix.cloud == 'gcp'
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_EPHEMERAL_SA }}

      - name: Destroy if expired
        if: steps.cfg.outputs.ready == 'true'
        env:
          CLOUD: ${{ matrix.cloud }}
        run: bash tools/dev/reap-expired.sh "$CLOUD"
```

```bash
# tools/dev/reap-expired.sh
#!/usr/bin/env bash
# Destroy ephemeral cells whose TTL has passed. One implementation for `make reap` (laptop) and
# ttl-reaper.yml (hourly): the expiry is read from each stack's own state (output expires_at), so
# both clouds work the same way and nothing depends on tag-search APIs.
#   bash tools/dev/reap-expired.sh aws gcp      # needs credentials for the clouds named
# Only *-dev stacks are ever considered; prod has no expiry and the facade refuses to give it one.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
now=$(date -u +%s)
status=0

for cloud in "$@"; do
  case "$cloud" in aws|gcp) ;; *) echo "skip unknown cloud: $cloud"; continue ;; esac
  stack="$REPO/infra/live/$cloud-dev/10-foundation"
  echo "== $cloud-dev"
  if ! terraform -chdir="$stack" init -input=false -no-color -lockfile=readonly >/dev/null; then
    echo "   init failed (credentials or state bucket?)"; status=1; continue
  fi
  expires=$(terraform -chdir="$stack" output -json 2>/dev/null | jq -r '.expires_at.value // empty')
  if [ -z "$expires" ]; then
    echo "   nothing deployed"; continue
  fi
  if [ "$expires" -gt "$now" ]; then
    echo "   alive for another $(( (expires - now) / 60 )) min (expires $(date -u -d "@$expires" +%FT%TZ))"; continue
  fi
  echo "   expired $(( (now - expires) / 60 )) min ago: destroying"
  # Destroy needs the stack's required variables; their values don't matter for a destroy plan.
  if TF_VAR_expires_at="$expires" TF_VAR_admin_cidrs='["192.0.2.1/32"]' \
       terraform -chdir="$stack" plan -destroy -input=false -no-color -lock-timeout=5m -out=reap.tfplan >/dev/null \
     && terraform -chdir="$stack" apply -input=false -no-color reap.tfplan; then
    echo "   destroyed"
  else
    echo "   DESTROY FAILED: the cell is still running and billing"; status=1
  fi
  rm -f "$stack/reap.tfplan"
done
exit $status
```

```yaml
# .github/workflows/ephemeral-up.yml
# Bring up an ephemeral managed cell (EKS or GKE) for a demo, at most 8 hours; ttl-reaper.yml
# destroys it after cb-expires-at. Same stack and same TTL rule as `make managed-up` on a laptop.
# Setup (once): apply infra/live/global/00-ci-identity, then in Settings → Environments create
# "ephemeral" (no required reviewers, deployment branches: main) with variables AWS_EPHEMERAL_ROLE,
# GCP_WIF_PROVIDER, GCP_EPHEMERAL_SA from that stack's outputs.
name: ephemeral-up

on:
  workflow_dispatch:
    inputs:
      cloud:
        description: Which cloud
        type: choice
        options: [gcp, aws]
        default: gcp
      ttl_hours:
        description: Lifetime in hours (1-8)
        type: choice
        options: ["1", "2", "3", "4", "5", "6", "7", "8"]
        default: "4"
      admin_cidr:
        description: Your public IP as a CIDR (e.g. 203.0.113.10/32); the only address the API admits
        type: string
        required: true
      admin_arn:
        description: "AWS only: your IAM ARN, granted cluster-admin (optional)"
        type: string
        required: false

permissions:
  contents: read

concurrency:
  group: ephemeral-${{ inputs.cloud }} # never two applies (or an apply and a reap) on one stack
  cancel-in-progress: false

jobs:
  up:
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    environment: ephemeral
    permissions:
      contents: read
      id-token: write # OIDC to AWS / GCP; no stored cloud keys
    env:
      CLOUD: ${{ inputs.cloud }}
      STACK: infra/live/${{ inputs.cloud }}-dev/10-foundation
    steps:
      - name: Refuse a world-open or malformed API allowlist
        env:
          ADMIN_CIDR: ${{ inputs.admin_cidr }}
        run: |
          if ! [[ "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(2[4-9]|3[0-2])$ ]]; then
            echo "::error::admin_cidr must be one IPv4 address or a small range (/24 to /32)"; exit 1
          fi

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_version: 1.15.9
          terraform_wrapper: false

      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        if: inputs.cloud == 'aws'
        with:
          role-to-assume: ${{ vars.AWS_EPHEMERAL_ROLE }}
          aws-region: ap-south-1

      - uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093 # v3.0.0
        if: inputs.cloud == 'gcp'
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_EPHEMERAL_SA }}

      - name: Plan and apply with a TTL
        env:
          TTL_HOURS: ${{ inputs.ttl_hours }}
          ADMIN_CIDR: ${{ inputs.admin_cidr }}
          ADMIN_ARN: ${{ inputs.admin_arn }}
          CI_ROLE: ${{ vars.AWS_EPHEMERAL_ROLE }}
          DOCKERHUB_USER: ${{ vars.DOCKERHUB_USER }}
        run: |
          expires=$(( $(date -u +%s) + TTL_HOURS * 3600 ))
          export TF_VAR_expires_at="$expires" TF_VAR_admin_cidrs="[\"$ADMIN_CIDR\"]"
          if [ "$CLOUD" = aws ]; then
            arns=$(jq -nc --arg ci "$CI_ROLE" --arg me "$ADMIN_ARN" '[$ci, $me] | map(select(. != ""))')
            export TF_VAR_admin_principal_arns="$arns"
          elif [ -n "$DOCKERHUB_USER" ]; then
            export TF_VAR_dockerhub_user="$DOCKERHUB_USER"
          fi
          terraform -chdir="$STACK" init -input=false -lockfile=readonly
          terraform -chdir="$STACK" plan -input=false -lock-timeout=5m -out=tfplan
          terraform -chdir="$STACK" apply -input=false tfplan
          {
            echo "### $CLOUD-dev is up"
            echo "Expires **$(date -u -d "@$expires" +%FT%TZ)** (reaped by ttl-reaper within the following hour)."
            echo
            echo "From the allowed address: \`make -C infra managed-check CLOUD=$CLOUD\`"
          } >> "$GITHUB_STEP_SUMMARY"
```

## 7. tools/affected_stacks.py

```python
#!/usr/bin/env python3
"""Map changed files → affected live stacks (directly, or via the modules they call)."""
import argparse, json, pathlib, re, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIVE = ROOT / "infra" / "live"
ORDER = {"10-foundation": "foundation", "20-bootstrap": "bootstrap", "30-traffic": "traffic"}
SOURCE = re.compile(r'source\s*=\s*"(\.\./[^"]+)"')

def changed(base: str) -> list[str]:
    out = subprocess.run(["git", "diff", "--name-only", f"{base}...HEAD"], capture_output=True, text=True, check=True)
    return [l for l in out.stdout.splitlines() if l.startswith("infra/")]

def module_closure(stack: pathlib.Path) -> set[pathlib.Path]:
    seen, todo = set(), [stack]
    while todo:
        d = todo.pop()
        for tf in d.glob("*.tf"):
            for rel in SOURCE.findall(tf.read_text()):
                m = (d / rel).resolve()
                if m not in seen and m.is_dir():
                    seen.add(m)
                    todo.append(m)
    return seen

def stacks() -> list[pathlib.Path]:
    return sorted(p for p in LIVE.glob("*/*") if p.is_dir() and any(p.glob("*.tf")))

def describe(p: pathlib.Path) -> dict:
    cell, layer = p.parent.name, p.name
    cloud = "global" if cell == "global" else cell.split("-")[0]
    env = "traffic-prod" if cell == "global" else cell
    return {"path": str(p.relative_to(ROOT)), "cloud": cloud, "env": env, "layer": ORDER.get(layer, layer)}

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--ordered", action="store_true")
    a = ap.parse_args()
    files = [(ROOT / f).resolve() for f in changed(a.base)]
    hit = []
    for s in stacks():
        deps = module_closure(s) | {s.resolve()}
        if any(any(str(f).startswith(str(d) + "/") for d in deps) for f in files):
            hit.append(describe(s))
    # smaller cell first (gcp before aws), like the release ring
    hit.sort(key=lambda h: (h["layer"], 0 if h["cloud"] == "gcp" else 1))
    result = {"stacks": hit}
    if a.ordered:
        result["layers"] = {k: [h for h in hit if h["layer"] == k] for k in ("foundation", "bootstrap", "traffic")}
    clouds = {h["cloud"] for h in hit if h["cloud"] in ("aws", "gcp")}
    result["one_sided"] = len(clouds) == 1
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
```

## 7b. tools/render_pr_comment.py

```python
#!/usr/bin/env python3
"""Render one sticky PR comment from per-stack artifacts (risk.json, conftest.json, infracost.json)."""
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
rows, details = [], []
for d in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("plan-")):
    risk = json.loads((d / "risk.json").read_text())
    cost = json.loads((d / "infracost.json").read_text()) if (d / "infracost.json").exists() else {}
    conf = json.loads((d / "conftest.json").read_text()) if (d / "conftest.json").exists() else []
    fails = sum(len(r.get("failures") or []) for r in conf)
    delta = cost.get("diffTotalMonthlyCost") or "0"
    icon = {"pass": "✅", "warn": "⚠️", "block": "⛔"}[risk["verdict"]]
    rows.append(f"| `{risk['stack']}` | {risk['counts']} | {icon} {risk['verdict']} | {fails} | {cost.get('currency', 'USD')} {delta}/mo |")
    for f in risk["findings"]:
        details.append(f"- **{f['verdict']}** `{f['address']}` — {f['why']} ({f['rule']})")

print("## CloudBridge IaC plan\n")
print("| Stack | add/change/destroy | Plan risk | Policy failures | Cost delta |")
print("|---|---|---|---|---|")
print("\n".join(rows))
if details:
    print("\n<details><summary>Findings</summary>\n\n" + "\n".join(details) + "\n</details>")
```

## 8. Conftest policies

```rego
# infra/policy/tags.rego
package main

import rego.v1

required := {"cb-cell", "cb-cloud", "cb-env", "managed-by"}

taggable(rc) if startswith(rc.type, "aws_")
taggable(rc) if startswith(rc.type, "google_")

tags(rc) := t if {
	t := rc.change.after.tags_all
} else := t if {
	t := rc.change.after.labels
} else := t if {
	t := rc.change.after.resource_labels
}

deny contains msg if {
	some rc in input.resource_changes
	rc.change.actions[_] in {"create", "update"}
	taggable(rc)
	t := tags(rc)
	missing := required - {k | t[k]}
	count(missing) > 0
	msg := sprintf("%s is missing labels/tags %v", [rc.address, missing])
}
```

```rego
# infra/policy/regions.rego
package main

import rego.v1

allowed_regions := {"ap-south-1", "asia-south1", "asia-south1-a", "global"}

deny contains msg if {
	some rc in input.resource_changes
	region := object.get(rc.change.after, "region", object.get(rc.change.after, "location", ""))
	region != ""
	not region in allowed_regions
	msg := sprintf("%s targets %s — CloudBridge keeps both cells in Mumbai for fair comparison and data residency", [rc.address, region])
}
```
Not every resource supports tags/labels; add an allowlist of exempt types (`aws_iam_role_policy_attachment`, `google_project_iam_member`, …) as you meet them, and unit-test policies with `conftest verify`.
