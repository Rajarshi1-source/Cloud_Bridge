# IaC pipeline: what to configure, and how it behaves

The workflows are safe to merge before any cloud exists: a stack whose identity isn't configured shows
"not planned" in the PR comment and fails nothing. This page is the switch-on list.

## Which stacks the pipeline runs

| Stack | Plan on PR | Apply on merge | Environment |
|---|---|---|---|
| `aws-budget/10-foundation` | yes | yes | `aws-budget` |
| `gcp-budget/10-foundation` | yes | yes | `gcp-budget` |
| `global/30-traffic` | yes | yes | `traffic-prod` |

Left out on purpose:

- `*-dev`: ephemeral, run by `ephemeral-up.yml` and the TTL reaper.
- `global/00-ci-identity`: creates the identities the pipeline would need, so a person applies it.
- `global/20-origin-tls`: its state holds a private key, and the plan identity is refused access to it.

## Switching it on

1. Apply the identities yourself, once:

   ```bash
   cd infra/live/global/00-ci-identity && terraform init && terraform apply
   ```

2. Set these from `terraform output`, under Settings > Secrets and variables > Actions.

   Repository variables:

   | Name | Value |
   |---|---|
   | `AWS_PLAN_ROLE` | output `AWS_PLAN_ROLE` |
   | `GCP_PLAN_SA` | output `GCP_PLAN_SA` |
   | `GCP_WIF_PROVIDER` | the existing Workload Identity provider |
   | `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_ACCOUNT_ID` | your zone and account |

   Repository secrets:

   | Name | Value |
   |---|---|
   | `CB_PLAN_KEY` | a long random string (`openssl rand -hex 32`): encrypts saved plans between jobs |
   | `INFRACOST_API_KEY` | optional: without it the cost delta reads "not measured", never zero |
   | `CLOUDFLARE_READ_TOKEN` | read-only token, for planning `30-traffic` |

3. Create three environments, each with required reviewers. Without reviewers, an apply runs unattended.

   | Environment | Variable or secret |
   |---|---|
   | `aws-budget` | variable `AWS_APPLY_ROLE` (output `apply_identities`) |
   | `gcp-budget` | variable `GCP_APPLY_SA` (output `apply_identities`) |
   | `traffic-prod` | variable `GCP_APPLY_SA`, secret `CLOUDFLARE_API_TOKEN` |

## What a PR shows

One sticky comment, updated in place, with a row per affected stack: change counts, cost delta and the
Conftest result. Both clouds sit side by side, and a change that plans on only one cloud is called out.
The static checks (tflint, Trivy, Conftest's own tests) are in the same comment.

The plan-risk verdict joins the comment in Week 8.

## What happens on merge

For each affected stack, in dependency order:

1. The plan job runs outside any environment with the read-only plan identity, and
   uploads the plan encrypted (kept 1 day) with its SHA-256 in the job summary.
2. The apply job waits in the environment for a reviewer.
3. After approval it decrypts the plan, checks the hash against the plan job's output, and applies exactly
   that file. If state moved in between, Terraform refuses the saved plan: re-run the workflow.

`concurrency: tf-<stack>` queues a second run instead of cancelling a running apply.

## Drift

`drift.yml` plans every pipeline stack nightly at 02:30 IST with the plan identity. Changes open or update
one issue per stack, labelled `drift`, listing the changed resource addresses but no values.

## Not yet proven

None of this has run against a real cloud:

- the OIDC and Workload Identity trust conditions
- the apply identities' permissions, which may turn out too narrow on the first real apply
- Conftest on a real `plan.json`: its rules are tested only against fixtures, so the first real plan could
  show a false positive
- the Infracost output, which needs an API key

Expect small fixes on first use, and record them in `.claude/skills/cloudbridge-iac-pipeline`.
