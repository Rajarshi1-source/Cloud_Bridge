# Local two-cell twin

Two k3s cells (`cb-aws-local`, `cb-gcp-local`) behind a Cloudflare-like edge, on this machine and
at $0. Use it to exercise Weeks 4–8 (lease allocator across two cells, parity checker, Prometheus
and Grafana, evacuation drills, Rollouts canaries) before the real go-live
(`docs/runbooks/week-2-go-live.md`). It is a stand-in for the **runtime** of the budget profile,
not for the clouds: see "What it does not prove".

```
              https://app.<domain>:8443  (curl --resolve to 127.0.0.1)
                         │
                ┌────────▼────────┐   weights from infra/live/global/30-traffic/terraform.tfvars.json
                │ edge (Traefik)  │   __cflb affinity cookie, /healthz/cell monitor, fallback cell
                └───┬─────────┬───┘
       TLS, verified│         │against the twin's "origin CA"
       ┌────────────▼──┐   ┌──▼────────────┐
       │ cell-aws (k3s)│   │ cell-gcp (k3s)│   each: Argo CD → platform-addons (Traefik, Rollouts,
       │ ring-main     │   │ ring-canary   │   NetworkPolicies, Postgres, Valkey) + 3 services
       └──────┬────────┘   └───────┬───────┘
              │ git (Argo CD)      │ docker.io pulls
        ┌─────▼─────┐        ┌─────▼──────┐
        │ twin-git  │        │ twin-mirror│  pull-through cache: one Docker Hub pull per image
        └───────────┘        └────────────┘
```

Week 4 adds, on the same network: `twin-registry` (service images built from the working tree),
`twin-access` (a Cloudflare Access stand-in in front of `admin-<cloud>`: service tokens, signed JWTs,
a JWKS endpoint), and `twin-cp-db` + `twin-allocator` (the real allocator, granting both cells through
the edge every 20 s, with a 90 s lease so an outage test takes minutes).

## Use

Everything runs in WSL (`Ubuntu-D`) and needs only Docker, git, python3, openssl and curl.

```bash
bash tools/dev/twin.sh up
```

```bash
bash tools/dev/twin.sh check
```

```bash
bash tools/dev/twin.sh outage aws
```

| Command | What it does |
|---|---|
| `up` | Certificates (once), working-tree snapshot, Ansible render of both cells, edge config, `docker compose up`, then waits until each cell answers `/healthz/cell` through its own ingress. First start: about 10–15 minutes (images, Argo CD, JVM start). |
| `sync` | Publishes the working tree again and makes Argo CD fetch it now. Use after editing charts, cell values or ring files. Uncommitted changes are included. |
| `weights` | Re-reads `terraform.tfvars.json` into the edge. Takes effect within seconds; the same validation as Terraform (sum 100; each 0 or ≥ 10). |
| `images [off]` | Builds the three services from the working tree into `twin-registry` and overlays their digests on the ring files, in the twin's snapshot only. `off` returns to the ring digests. |
| `promote` | Skips the canaries: deletes the Rollouts and their HPAs so Argo CD recreates them with only the new images, and waits. Run it after `images`; the old and new pods don't fit in a cell together. |
| `check` | Both origins healthy; 200 requests split within ±10 points of the weights; the `__cflb` cookie pins a user; `POST /orders` without a key → 400; `/admin/**` on the public host → 404. |
| `leases` | Week 4's "done when" through the edge: the allocator's grants stay within stock, forged grants fail at every layer, grant bounds, an order survives pod restarts, a repeated POST returns the same order, 200 orders against 20 units on both cells, and an outage's quantity comes back only after expiry + 60 s. Run `images` and `promote` first until a release carries the code. |
| `outage aws\|gcp` | Pauses the whole cell (every container freezes, as in a cloud outage), measures how long until 10 of 10 requests reach the other cell, then restores it and measures the return. |
| `status` | Argo CD apps, pods and origin health per cell. |
| `kubectl aws\|gcp ARGS…` | The cell's bundled kubectl. |
| `down` / `purge` | Stop, keeping data and certificates / delete volumes and `~/.cache/cloudbridge-twin`. |

Call the edge yourself:

```bash
curl -si --cacert ~/.cache/cloudbridge-twin/pki/ca.crt --resolve app.cloudbridge.example:8443:127.0.0.1 https://app.cloudbridge.example:8443/healthz/cell
```

kubectl without installing it (k3s bundles one; plain `docker compose exec` lacks `TWIN_DIR`):

```bash
bash tools/dev/twin.sh kubectl gcp -n cb-app get pods
```

## Same code as the budget cells

| Budget VM | Twin |
|---|---|
| k3s `v1.36.5+k3s1`, config from role `k3s_server` | same version (`rancher/k3s` image), config from the same template |
| `cell_secrets`, `origin_tls`, `argocd_autodeploy` roles | the same roles, via `ansible/playbooks/twin.yml` |
| Argo CD 10.10.5 HelmChart in the k3s auto-deploy dir | same file, same directory (mounted) |
| Root ApplicationSet from `gitops/bootstrap/applicationset.yaml.tftpl` | same template; only `repoURL`/`targetRevision` point at the twin's git server |
| `gitops/cells/cb-<cloud>-budget/values.yaml` | `cb-<cloud>-local/values.yaml`: identical except `cell`, `secretStore` and `network.accessCidrs` (the stand-in's address, not Cloudflare's ranges) |
| Ring files, charts, NetworkPolicies, Pod Security `restricted` | unchanged |
| Cloudflare LB: pool weights, cookie affinity, monitor, fallback pool, Full (strict) | Traefik weighted + failover services generated by `tools/dev/twin/edge_config.py` |

## What it does not prove

Plan a real go-live for these; the twin cannot fail them for you.

- **Cloud APIs**: VPCs, firewalls, IAM, EKS/GKE, RDS/Cloud SQL, secret managers, SSM/IAP access.
  Offline coverage is the `terraform test` mock-provider suites (Terraform and OpenTofu, in CI).
- **Cloudflare itself**: the v5 provider's attribute names, Access service tokens and JWT claims,
  multi-region monitors, anycast. The edge reproduces the LB's *behaviour*, not its API.
- **Timing**: the edge's monitor runs every 10 s (Cloudflare: 60 s, retries 2), so the twin's
  failover time is much shorter than the cloud one. Measure the real number in a Week 7 drill.
- **Real Access**: `twin-access` issues JWTs shaped like the documented ones. The claim names and
  what a real service token's JWT carries still need checking against a real Access application.
- **Managed data and secrets**: RDS, Cloud SQL, ElastiCache, Memorystore, External Secrets and
  `20-bootstrap` have only mock-provider tests and rendered manifests.
- **Fit on a real 2 GiB VM**: the cell container has 3 GiB here and used 2.7 GiB under `leases`
  (page cache included). Each JVM sat near 300 MiB against limits of 384 and 416 MiB.

## Measured on this machine (1 Nov 2026)

WSL `Ubuntu-D` with 7.5 GiB, weights `{aws: 70, gcp: 30}`:

| Run | Result |
|---|---|
| `check`, 200 requests without a cookie | `cb-aws-local=140 cb-gcp-local=60`; cookie pinned 20/20; `POST /orders` without a key → 400; `/admin/**` → 404 |
| `outage aws` | all traffic on `cb-gcp-local` after 18 s; 50/50 requests there; back in rotation 1 s after unpause |
| `outage gcp` | all traffic on `cb-aws-local` after 14 s; 50/50 requests there; back in rotation 1 s after unpause |

Week 4 (2 Nov 2026), service images from the working tree, allocator interval 20 s, lease 90 s:

| Run | Result |
|---|---|
| `check` | passed: `cb-aws-local=140 cb-gcp-local=60` |
| `leases`, grants | `aws/SKU-1=630`, `gcp/SKU-1=270` (70/30 of 90% of 1000); `twin-other.access`, a forged signature, no token and a wrong secret all refused; lease unchanged |
| `leases`, overselling | 200 orders against 20 units on both cells at once: 19 accepted, 181 `409`, sold 38 of stock 39. Grants are rounded down from 90% of what's left, so the last unit stays unsold: the allocator undersells, as designed |
| `leases`, outage | gcp paused: aws went from 630 to 461 (gcp's quantity stays committed), and back to 630 at 172 s, after expiry + 60 s. `STOCK OVERRUN` logged 0 times |

The failover time is the edge monitor (10 s interval, 5 s timeout) plus in-flight requests timing
out; with Cloudflare's 60 s monitor and 2 retries expect minutes, not seconds. The return is fast
because the monitor's last probe, frozen with the cell, completes as soon as the cell resumes.

## What the twin found (and what to expect)

- **Rollouts and the postgres StatefulSet stayed OutOfSync forever** with Argo CD's default
  client-side diff. The HPA owns a Rollout's `spec.replicas` through the scale subresource, and the
  API server fills in defaults inside `volumeClaimTemplates`. Fixed for every cell (budget and
  managed) by `argocd.argoproj.io/compare-options: ServerSideDiff=true` in the root ApplicationSet.
- **First sync shows errors for a few minutes**: the service apps sync before `platform-addons` has
  installed the Rollout CRD (`no matches for kind "Rollout"`). Argo CD's retry (15 s, doubling, at
  most 5 min) heals it without help. Same on the budget VMs, so don't chase it during a go-live.
- **A frozen cell hangs requests instead of refusing them**: a paused (or wedged) origin still
  completes the TCP handshake and never answers. Requests already sent to it wait for the edge's
  response deadline (none in the twin; 100 s and a 524 at Cloudflare) until the monitor marks it
  down. `outage` gives each request a 5 s client deadline and counts these as `none`.
- **Memory**: a fully synced cell uses about 2 GiB. Both cells, the edge, git and the mirror need
  about 5 GiB of WSL memory; stop other Compose projects first (their `restart: unless-stopped`
  containers come back with WSL and starved the twin until WSL hung).

- **Python 3.13+ rejected the twin's CA** (`CA cert does not include key usage`): stricter default
  TLS checks. `pki` now issues a CA with key usage and leaves with an authority key ID, and replaces
  an older CA on the next `up`. Real Cloudflare certificates aren't affected.
- **After a Docker restart `twin-git` or `twin-access` wouldn't start** (`Address already in use`):
  another container had taken their fixed address. Dynamic addresses now stay above `.128`.
- **The gateway answered 404 on the admin host**: its `host()` route predicate compares the whole
  `Host` header, and the twin's port 8443 was in it, while the security chain compares the hostname.
  Both now compare the hostname. Standard ports hide this, so a real cell wouldn't have shown it.
- **A cell ran out of memory and looped.** A starting JVM pegs its CPU, so the HPA added a second
  replica of every service; with a canary's pods that made nine JVMs in a cell sized for three. Budget
  and twin cells now have `replicas.max: 1`. A canary still doubles the JVMs for a few minutes, which
  is untested on a real 2 GiB VM. The crash also left a stale `index.lock` in Argo CD's repo cache.

## Troubleshooting

- **A cell never gets ready**: `bash tools/dev/twin.sh status`. Argo CD apps stuck `Unknown` usually
  means the repo-server can't reach `twin-git` (`docker compose -f tools/dev/twin/compose.yaml logs twin-git`).
- **Pods `ErrImagePull` with `toomanyrequests`**: Docker Hub's anonymous limit. The mirror keeps
  every image it has fetched, so a retry later finishes; images already cached never count again.
- **Argo CD apps `Unknown` with `index.lock: File exists`**: a crash left its git cache locked. Delete
  the repo-server pod (its cache goes with it):
  `bash tools/dev/twin.sh kubectl aws -n argocd delete pod -l app.kubernetes.io/name=argocd-repo-server`.
- **`Wsl/Service/0x8007274c` from `wsl`**: Windows is short of memory and the VM stopped answering in
  time. Close something and retry; with both cells up, WSL holds about 6.5 GB.
- **Out of memory**: each cell is capped at `CB_TWIN_CELL_MEM` (default 3g). WSL gets half the host's
  RAM by default; raise it in `%UserProfile%\.wslconfig` (`[wsl2]` `memory=10GB`) if both cells don't fit.
- **WSL stops Docker when idle**: keep a `wsl -d Ubuntu-D -- sleep 7200` running while you use the twin.
- **Subnet clash**: set `CB_TWIN_NET` (default `172.29.80`, the first three octets).
