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

The central observability stack runs beside them, from the same files a real deployment will use
(`observability/`): `twin-prometheus`, `twin-alertmanager`, `twin-blackbox` and `twin-grafana`, plus
`twin-alert-sink`, which records what Alertmanager would send to Slack and Event-Driven Ansible. Each
cell's Prometheus agent pushes to `metrics.<domain>` through the edge and the Access stand-in.

- Grafana: <http://127.0.0.1:3000> (read-only, no login, this machine only)
- Prometheus: <http://127.0.0.1:9090>

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
| `observe` | Week 5 through the edge: only the metrics token can write, and only the write path is published; both cells report with their labels; the recorded split matches the weights; every rule evaluates; every panel of the five dashboards runs its query. |
| `burn aws\|gcp` | Stops order-service for real (and Argo CD, which would heal it) and sends orders at the origin until `CellSLOBurnFast` fires and reaches the Slack and EDA stand-ins, then restores both. Takes about 10 minutes. |
| `capacity aws\|gcp` | k6 at rising rates against the cell's origin, then writes the highest step that held to `gitops/cells/<cell>/capacity.yaml`. Takes about 15 minutes. It writes to your working tree: review the diff. |
| `outage aws\|gcp` | Pauses the whole cell (every container freezes, as in a cloud outage), measures how long until 10 of 10 requests reach the other cell, then restores it and measures the return. |
| `parity` | Week 6: real drift in `cb-aws-local`, one check at a time (chart version, image digest, CPU request, env var, HPA max, NetworkPolicy, Flyway row), with Argo CD and Rollouts stopped on it. Each must fail exactly its own check and then be restored. A frozen `cb-gcp-local` must read as unknown, score 0. Stores snapshots, so the failures show on the dashboard. About 4 minutes. |
| `cost` | Week 6: the ledger on made-up FOCUS files in a scratch database it drops afterwards: idempotent re-ingest, a restated file, credits, unallocated cost and unit costs worked by hand. Then that the real ledger is still empty, the volume query against real series, and the `cp.<domain>` path through Access. About 1 minute. |
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
| `gitops/cells/cb-<cloud>-budget/values.yaml` | `cb-<cloud>-local/values.yaml`: identical except `cell`, `secretStore`, `network.accessCidrs` (the stand-in's address, not Cloudflare's ranges) and `observability` (on here, before the real central receiver exists) |
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
  (page cache included). Each JVM sat near 300 MiB against limits of 384 and 416 MiB. Week 5 adds the
  Prometheus agent (about 100 MiB) and a larger Traefik (up to 256 MiB).
- **The real metrics path**: the agent's write through real Cloudflare Access, and the central stack on
  the control-plane VM. The Slack and EDA deliveries reached stand-ins.
- **The IaC pipeline**: nothing here runs GitHub Actions, OIDC or a saved-plan apply. See
  [iac-pipeline.md](iac-pipeline.md).
- **Real billing**: the AWS Data Export, the BigQuery FOCUS view, tag spelling in a real export and OpenCost
  have never been read. Every amount `cost` handles is made up (currency `XXX`), and none reaches the real ledger.
- **Managed parity adapters**: `AwsManagedFacts` and `GcpManagedFacts` run on fixtures only.

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

Week 5 (3 Nov 2026), service images from the working tree:

| Run | Result |
|---|---|
| `observe`, write path | No token, the allocator's token and a wrong secret each get 403; the metrics token passes; a query through the metrics host gets 404 |
| `observe`, split | 900 requests through the edge: `cb:split:observed` 70% and 30%, weights 70/30 |
| `observe`, rules and Grafana | 18 rules evaluate, the probe through the edge succeeds, and all 34 panels of the five dashboards run their queries |
| `burn aws` | order-service stopped: `CellSLOBurnFast` fired on `cb-aws-local` and reached the Slack and EDA stand-ins with the cell's label; order-service and Argo CD restored |
| Cell paused | `CellMetricsSilent` fired after 616 s (5 minute lookback plus `for: 5m`) and reached Slack 30 s later; cleared after the cell returned |
| `capacity aws` | 40 RPS held (p95 27 ms, no errors); 80 RPS failed (p95 3.9 s, 25% errors). Per pod: gateway 40, order 7.7, inventory 47.8 |
| `capacity gcp`, twice | 10 RPS, then 20 RPS (p95 29 ms, no errors), which is the recorded figure. The next step failed both times on the gateway's breaker fallback, with p95 still under 60 ms |
| Agent | 81 to 105 MiB against its 128 MiB limit, no restarts in 90 minutes |

**Read the capacity numbers as a lower bound.** Identical cells measured 20 and 40 RPS, and one cell 10 and 20 across runs. The failures with low latency came from an open circuit breaker after a stall in a cell sharing this machine, not from running out of capacity. The tool keeps the step before the first failure, so noise can only lower the number. The figures say nothing about a budget VM.

Week 6 (3 Nov 2026), dashboard at `http://127.0.0.1:3001`, API at `http://127.0.0.1:8010`:

| Run | Result |
|---|---|
| `parity`, drift in one live cell | Chart version 0.914, image digest 0.857, CPU request 0.943, env var 0.886, HPA max 0.914, NetworkPolicy 0.943, Flyway row 0.857. Each failed its own check and nothing else. Restored to 1.000, and no rollout started |
| `parity`, frozen cell | All 11 checks unknown, score 0.000, exit 1 |
| `iac-check.sh parity`, one line changed in one cell's values | Chart version 0.842, max replicas 0.842, requests 0.895, env var 0.789. Budget, dev and local are otherwise 1.000 |
| `cost`, sample files | Re-ingest changed nothing; a restated file replaced its rows; order-service 5.0000 then 5.5000 per 1,000, api-gateway 0.5000, all as worked by hand; a credit of -100 stayed out; unallocated 5 and shared-with-no-share 7 were shown |
| `cost`, the real ledger | Empty: `GET /cost` has no unit costs, `/metrics` no billing gauge, and `CostDataStale` fires |

## What the twin found (and what to expect)

- **`iac-check.sh policy` failed now and then with the twin up, and it wasn't memory pressure as first guessed (Week 6).** Directory reads on `/mnt/d` fail with `readdirent: cannot allocate memory` while the twin runs, with over 1.4 GiB still available and no OOM kill. 25 runs each: `/mnt/d` with the twin up failed 8 times at 8 workers and once at 1 worker; a Docker volume with the twin up, and either path with it down, never failed. Why WSL's mount does this is inference (fragmentation), not proven. Every `iac-check.sh` step now reads a snapshot of the tree in a Docker volume: 12 of 12 with the twin up, and a planted unused variable is still caught. A tree walker can quietly pass on part of a tree here, so anything else that walks `/mnt/d` is suspect; `git add -A` in `publish` could miss an untracked file, though tracked ones are safe.
- **Prometheus and Grafana kept their old config after an `up` (Week 6).** The files are mounted, so a changed scrape job never loaded, and the staleness alerts look the same either way. `up` and `sync` now reload both, and `observe` fails if the API isn't being scraped.
- **A 503 on `POST /orders` doesn't mean the order failed (Week 6).** `leases` got one about 3 minutes after an `up` that rebuilt images. Metrics show order-service taking 7.38 s and **returning 201**, while the gateway's fallback answered the client. It wasn't an open breaker, which needs 20 calls when that route had seen 2. It was the gateway's 2 s read timeout, reproduced by freezing order-service for 4 s, twice: 503 at 2.02 s, then 409 with the same key, then 201 with the order once it committed. That's the order the incident showed, and the same key is safe to retry.
  - **What's still unknown is why order-service took 7.38 s.** A cold start alone doesn't do it. Its share of the first order after restarting all three services was 0.74 and 0.82 s on an idle machine, and 1.29 s during a Next.js build, so about 0.7 s or more inside the timeout. The fallback also took 5.74 s against 2.02 s when reproduced, so the gateway was slow too, which points at the machine rather than one service. Those pods had sat idle for about 80 minutes before their first order, against 30 s in these trials, so paged-out memory is a suspicion, not a finding.
  - **A cold cell is still slow.** The client waited 1.75 to 2.20 s for the first order on an idle machine and 2.37 to 3.52 s just after or during a build, against about 0.05 s warm, and most of that is the gateway's own cold start. All of those returned 201. Week 7's pre-warm should put a real order through before a cell takes traffic.
  - `leases` now retries with the same key and prints how many retries it took. Before this, a failed POST printed "ok, same order", because the two error bodies matched.
- **`kubectl wait` failed `leases` on a pod it had just seen deleted (Week 6).** The check now polls for three running pods.
- **The volume job finds nothing until Prometheus is a day old.** It reads whole UTC days and today isn't over. `cost` proves the queries against today so far, and writes nothing.

- **Traefik took the whole ingress down under load (Week 5).** Its 128 MiB limit left almost nothing above its 118 MiB idle use, and the chart sets `GOMEMLIMIT` from the limit. At 40 RPS it spent 14 CPUs in garbage collection, failed its liveness probe and refused connections. At 256 MiB it peaked at 186 MiB through 80 RPS with no restarts. The chart already sets that variable, so adding your own gives a duplicate entry and Argo CD stops comparing the app.
- **The observed split read 50/50 with no users (Week 5).** The allocator's admin calls reach each cell whatever the weights say. The rule now counts user routes only, and no user traffic means no data.
- **A stat panel can't show a timestamp (Week 5).** It printed "no measurement yet" with data in hand. Those queries now return epoch milliseconds, and `observe` fails if a stat panel has no number.
- **Grafana kept serving old dashboards after they were regenerated.** `up` and `sync` now restart `twin-grafana`.

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
