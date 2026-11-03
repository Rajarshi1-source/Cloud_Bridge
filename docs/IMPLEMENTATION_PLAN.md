# CloudBridge — Implementation Plan (MVP + Differentiators)

> Build plan derived from `CloudBridge_Implementation_Plan_REV2.md` (Rev 2.1, the single source of truth) and the skills in `.claude/skills/` (the default coding rules). Created 14 Oct 2026. **Phase 0 is done** (see the status note under §2); Weeks 1–8 are next.

## Context

CloudBridge deploys the same Spring Boot services to AWS and GCP from one Terraform codebase. Ansible runs the VM configuration and the evacuation drills, and Cloudflare splits traffic 70/30. On top of that, a control plane proves three things: the two clouds still match (parity), the smaller cloud can take all the traffic (evacuation drills), and which cloud costs less per request (cost ledger).

**Sources, in priority order:**
1. `CloudBridge_Implementation_Plan_REV2.md` is the single source of truth.
2. The final skills in `.claude/skills/` are the default rules for all code. Where the skills fixed Rev 2 after verification, Rev 2 gets patched to match (Phase 0.6), so the two stay consistent.
3. `CloudBridge_Implementation_Plan.md` (Rev 1) is used only where Rev 2 refers back to it. Its defects C1–C23 must never be copied.

**Phase 0 (done 14 Oct 2026)** covered:
- writing `references/security-and-api.md` in the cell-services skill
- fixing Resilience4j and the other Boot 4 lines in that skill, then repackaging it
- installing the skills so Claude Code actually loads them
- patching Rev 2
- deleting the initial skill copies
- moving the services to `services/`
- saving this plan into `docs/`

Weeks 1–8 then run phase by phase in later sessions.

---

## 1. What already exists (verified 14 Oct 2026)

| Area | State | Problem |
|---|---|---|
| Three services | Initializr boilerplate only (an `*Application.java`, a context-load test, `TestcontainersConfiguration`) under `api-gateway/api-gateway/`, `order-service/order-service/`, `inventory-service/inventory-service/` | Nested directories. The plan, skills and CI all expect `services/<svc>/` |
| `pom.xml` | Boot 4.1.1 and Java 21. Gateway is on Spring Cloud 2025.1.3 with `gateway-server-webmvc`, `circuitbreaker-resilience4j`, `security` and `oauth2-resource-server`. Order and inventory have `webmvc`, `jdbc`, `flyway`, `data-redis`, `validation`, `actuator`, Prometheus and Testcontainers 2.x | Order and inventory lack `resilience4j-spring-boot4` 2.4.0 and `spring-boot-starter-aspectj`. Gateway lacks `jdbc` and the PostgreSQL driver, which the `/healthz/cell` DB check needs |
| Tests | `TestcontainersConfiguration` uses `postgres:latest` and `redis:latest` | Must pin `postgres:18.4-alpine` and `valkey/valkey:9.0-alpine` (never `:latest`) |
| `application.yaml` | Only `spring.application.name` | Everything else is still to build |
| Root clutter | `api-gateway.zip`, `order-service.zip`, `inventory-service.zip` (Initializr downloads) | Delete them; the extracted sources are in git |
| Infra, Ansible, gitops, control plane, CI | Nothing yet | Weeks 1–8 |
| Skills in `.claude/skills/` | Flat `cloudbridge-*.SKILL.md` files plus `.skill` zips | **Claude Code does not load them.** It discovers skills only at `.claude/skills/<name>/SKILL.md`, and none of the nine appear in this session's skill list |
| Toolchain (checked) | Java 21.0.11, Python 3.14.6 | `docker` isn't on PATH, and Terraform and Ansible aren't installed (see §5) |

### 1.1 Which skill files are final, and which to delete (checked by hash and content)

Initial versions came from commit `f00975d` (root). Final versions came from commit `400ae6d` (`.claude/skills/`).

| File set | Root (initial) vs `.claude/skills` (final) |
|---|---|
| 7 skills: ansible-ops, cell-services, cloudflare-traffic, finops-steering, gitops-delivery, iac-pipeline, terraform-cells | They differ, and only the final versions contain the verification fixes. For example, the final versions alone have `reversal_factor`/`last_direction` (recommender oscillation guard), the Terramate switch trigger, the extra `÷ fanout` site, and the audited override step. |
| 2 skills: observability-dashboard, parity-contract | Byte-identical (same SHA-256), so the root copy is redundant |
| `CLOUDBRIDGE_SKILLS_INDEX.md` | Root is the 63-line pre-verification index. The final one is 172 lines, with "Status: verification complete", 57/57 routing and 112/112 benchmark |
| `cloudbridge-skill-evals.zip` | Root is 13.5 KB (scripts only). Final is 745 KB (scripts, results, graded answers, `review.html`) |

**Conclusion:** `.claude/skills/` holds the final version of every file.

**Delete these 20 root files.** They stay recoverable from commit `f00975d`.
- 9× `cloudbridge-*.SKILL.md`
- 9× `cloudbridge-*.skill`
- `CLOUDBRIDGE_SKILLS_INDEX.md`
- `cloudbridge-skill-evals.zip`

**Inside `.claude/skills/`, a second source of confusion:** each skill would exist three times (flat `.SKILL.md`, `.skill` zip, and the new directory). After Phase 0 there will be:
- **Editable source (the only one):** `.claude/skills/<name>/SKILL.md` + `references/`. Claude Code loads this.
- **Built artifact:** `.claude/skills/<name>.skill`, always rebuilt from the directory by `tools/skills/package_skill.py`. Never edited by hand.
- **Deleted:** the nine flat `.claude/skills/cloudbridge-*.SKILL.md` copies. The directory's `SKILL.md` is the readable copy, so a third copy would only drift.
- `CLOUDBRIDGE_SKILLS_INDEX.md` and `cloudbridge-skill-evals.zip` stay in `.claude/skills/`.

### 1.2 Places where the skills correct Rev 2 (the skills win; Rev 2 gets patched in 0.6)

| Rev 2 | Corrected rule (from the skills) |
|---|---|
| §15.2 `capacity = min(hpa_max × per_pod_rps × fanout_factor)` | `capacity_rps = min over services(hpa_max × per_pod_rps / fanout)`. HPA sizing is the inverse: `maxReplicas = ceil(1.2 × peak_gateway_rps_all_cells × fanout / per_pod_rps)`. §29 Q8 gets the same fix |
| §14.2 check `hpa.bounds` | `hpa.max`: max replicas must be equal; min may differ by profile |
| §16.2 recommender | The skill version adds a 2σ significance test, a pessimistic monotone p95 fit, a no-extrapolation limit (+0.10), safety-first handling, reversal hysteresis (×2), `max_step` 0.10 while `distinct_shares` < 3, and hysteresis of 2% instead of 5%. It also adds §6b `last_direction()` |
| §19 plan-risk | The `allow-destructive` override must be audited: POST to `plan_risk_reports` plus a PR comment |
| §9.2 cell schema (one shared schema) | Separate `orders` and `inventory` schemas, each owned by its own service. The idempotency key is a uuid PK with a `PENDING/COMPLETED/FAILED` status. The order flow is a claim → reserve → commit saga, with no DB transaction held open across HTTP |
| Not in Rev 2 | Resilience4j `resilience4j-spring-boot4` 2.4.0 and Spring Cloud 2025.1.3 get added to the §B version matrix |

### 1.3 Gaps that no skill covers yet (scheduled below)

1. **Admin API auth.** It's only a code comment today. Phase 0.1 fixes it.
2. **Lease allocator.** Rev 2 §23.3 describes it, but no starter code exists in any skill. Week 4 builds it.
3. **Per-cell admin hostnames.** The Cloudflare Access app, service token and DNS records belong to the cloudflare-traffic stack and aren't in its starter code yet. Week 2 adds them; that skill gets an update in a later session.

---

## 2. Phase 0 (completed 14 Oct 2026)

> Status: all items below are done. All three services build (`mvnw -DskipTests package`), and their context-load tests pass under Testcontainers on `postgres:18.4-alpine` / `valkey/valkey:9.0-alpine`, run with `tools/dev/test-services.sh` against the WSL2 Docker Engine (see §5).

### 0.1 Write `references/security-and-api.md` (cloudbridge-cell-services only, no new skill)

The target file is `.claude/skills/cloudbridge-cell-services/references/security-and-api.md`. Planned sections:

**§1 Threat model: the gap**
- `POST /admin/leases/grant` decides how much stock a cell may sell.
- The allocator runs on the GCP VM and reaches the AWS cell through Cloudflare. A NetworkPolicy can't tell that call apart from public traffic.
- Origin lock-down to Cloudflare IP ranges isn't authentication either: any Cloudflare customer can proxy requests to your origin IP.
- So without enforced auth, a forged grant (huge quantity, high epoch) either inflates stock, which means overselling, or fences out the real allocator forever.

**§2 Route list (the API surface)**

Two hostnames per cell:
- **Public:** `app.<domain>`, served via the load balancer.
- **Admin:** `admin-<cloud>.<domain>`, a proxied DNS record pointing straight at that cell's origin rather than the LB, because the allocator must reach one specific cell. A single label keeps it under Cloudflare Universal SSL.

| Host | Method + path | Upstream | Auth | Notes |
|---|---|---|---|---|
| app | `GET /healthz/cell` | gateway (local) | none | Cloudflare monitor; result cached 2 s; no rate limit |
| app | `POST /orders` | order-service | none (public demo) | `Idempotency-Key` required, else 400 at the gateway |
| app | `GET /orders/{id}`, `GET /orders?customerId=` | order-service | none | Cell-local; 404 if the order lives in another cell |
| app | `GET /inventory/{sku}` | inventory-service | none | Cache-aside read model |
| app | `/admin/**` | — | — | **404** at the gateway, so the path isn't advertised |
| admin | `POST /admin/leases/grant`, `GET /admin/leases/report` | inventory-service | Access JWT + `ROLE_LEASE_ALLOCATOR` | Everything else on the admin host returns 404 |
| internal | `POST /reservations` | inventory (from order-service only) | NetworkPolicy | Never routed by the gateway |
| internal | `/actuator/**` | management port **9080** | NetworkPolicy (Prometheus agent only) | Not in the Ingress |

**§3 Admin authentication: Cloudflare Access with JWT validated at the origin**
- **Cloudflare side:** a Cloudflare Access application on `admin-<cloud>.<domain>/admin/*` with a Service Auth policy that allows only the allocator's service token. The allocator sends `CF-Access-Client-Id` and `CF-Access-Client-Secret`, read from GCP Secret Manager.
- **Gateway:** OAuth2 Resource Server validates `Cf-Access-Jwt-Assertion` using a custom `BearerTokenResolver` that reads that header:
  - JWKS: `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`
  - issuer: `https://<team>.cloudflareaccess.com`
  - audience: the app's AUD tag
  - exp/nbf: 30 s clock skew
  - Authorities: claim `common_name` (the service-token client ID) must be in `cloudbridge.admin.allowed-service-tokens`; then the request gets `ROLE_LEASE_ALLOCATOR`.
  - Verify the claim names against Cloudflare docs on build day.
- **Spring Security 7 config sketch:**
  - Two ordered `SecurityFilterChain` beans. The admin chain matches host + `PathPatternRequestMatcher` on `/admin/**`. The public chain does permitAll on the public routes, denyAll elsewhere, and returns 404 for `/admin/**`.
  - Both chains are stateless, with CSRF disabled (JSON API, no cookie auth).
  - The `X-CB-Cell` header is added by a filter.
  - `AntPathRequestMatcher` was removed in Security 7, so it's not used.
- **Defence in depth in inventory-service:**
  - The gateway forwards the header unchanged. Inventory-service validates the same JWT with the same config and requires the same role. This needs `spring-boot-starter-security` + `spring-boot-starter-security-oauth2-resource-server` in inventory, added in Week 4.
  - NetworkPolicy lets inventory:8082 accept traffic only from gateway and order-service pods.
- **Optional:** Cloudflare Authenticated Origin Pulls (mTLS). Interview line: "IP allowlists say *from Cloudflare*, not *from me*."

**§4 Grant semantics hardened against forged or buggy grants** (applies even when auth passes)

| Rule | Enforcement | Response |
|---|---|---|
| Fencing | `epoch > current` (existing I4 SQL) | 409 problem `stale-lease-epoch` |
| Epoch jump cap | `epoch ≤ current + 1000` (property `max-epoch-jump`) | 422 `lease-grant-out-of-bounds`. Stops one bad grant from burning the epoch space |
| Lease TTL cap | `now < expires_at ≤ now + 20 min` | 422 |
| Quantity cap | `0 ≤ remainingQty ≤ products.max_cell_grant` (new expand migration column) | 422 |
| Idempotent replay | Same `(sku, epoch)` with the same quantity returns 200 `{replayed:true}` | Safe allocator retries |
| Audit | `inventory.lease_grant_log(sku, epoch, granted_qty, expires_at, actor, jti, outcome, received_at)` | Every attempt, including rejected ones |

The renewal direction is defined here and fixes an inconsistency in the current SKILL.md:
- The cell never calls out. The allocator polls `GET /admin/leases/report` and re-grants with `POST /admin/leases/grant` (epoch + 1) every 5 min.
- The SKILL.md line "cell renews via `POST /admin/leases/renew`" gets rewritten to match.

**§5 API contract**
- **`Idempotency-Key`:**
  - A UUID, required on `POST /orders`, retained 24 h.
  - Same key + same body returns the original status and body plus `Idempotent-Replayed: true`.
  - Same key + different body returns 422 `idempotency-key-reused`. `PENDING` returns 409 `request-in-progress` with `Retry-After: 1`. `FAILED` may be retried with the same key.
  - The body hash is SHA-256 of the canonical record JSON.
  - It is **cell-scoped**. The honest limitation: a failover mid-request can create a cross-cell duplicate. It's detectable by `reservation_id` and is documented.
- **Errors:** RFC 9457 `ProblemDetail` as `application/problem+json`:
  - `type` = `https://<domain>/problems/<slug>`, plus `title`, `status`, `detail`, `instance`, and extensions `cell` and `traceId`.
  - Catalog:
    - **400:** `missing-idempotency-key`, `validation-failed` (with an `errors[]` array)
    - **401 / 403:** admin only
    - **404:** not found
    - **409:** `out-of-stock-in-cell` (with `sku`), `request-in-progress`, `stale-lease-epoch`
    - **422:** `idempotency-key-reused`, `lease-grant-out-of-bounds`
    - **429:** `rate-limited`
    - **503:** `overloaded`, `dependency-unavailable`
  - Implemented with a `@RestControllerAdvice` extending `ResponseEntityExceptionHandler`.
- **Rate limits:**
  - Keyed on `CF-Connecting-IP`, which is trustworthy only because the origin is locked to Cloudflare.
  - Limits: GET 120/min, `POST /orders` 30/min.
  - Headers `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`; on 429, also `Retry-After`.
  - Uses Valkey `rl:{client}:{window}` and fails open to a local token bucket.
- **Load shedding:** 503 `overloaded` with `Retry-After: 2`. `/healthz/cell` and actuator are excluded.
- **CORS:**
  - Allowed origins: `https://cp.<domain>`, plus `http://localhost:3000` in the `local` profile.
  - Allowed methods: GET, POST, OPTIONS. Allowed headers: `Content-Type`, `Idempotency-Key`.
  - Exposed headers: `X-CB-Cell`, `Idempotent-Replayed`, `RateLimit-*`, `Retry-After`.
  - No credentials, `maxAge` 600, and no CORS on `/admin/**`.
- **Input limits:** body ≤ 16 KB; 1–50 items; qty 1–100; `pricePaise ≥ 0`. Bean Validation on records.
- **Headers:** `X-Content-Type-Options: nosniff`; `Cache-Control: no-store` on order responses. HSTS is set at Cloudflare.

**§6 Code:** `AdminSecurityConfig`, `CfAccessTokenResolver`, `ServiceTokenAuthoritiesConverter`, the public chain, `ProblemCatalog` / advice, `RateLimitFilter`, `CorsConfig`, the hardened `LeaseController` plus V2 migration SQL, and `application.yml` properties (`cloudbridge.admin.*`, `management.server.port: 9080`).

**§7 Tests** (`spring-security-test` `jwt()` and a `@MockitoBean JwtDecoder`):

| Scenario | Expected |
|---|---|
| Admin host, no JWT | 401 |
| Wrong `aud` | 401 |
| `common_name` not allowlisted | 403 |
| Public host + valid JWT on `/admin/**` | 404 |
| Epoch jump too large / TTL too long / quantity over cap | 422 each |
| Older epoch | 409 |
| Same-epoch replay | 200 |
| `POST /orders` without the key | 400 |
| CORS preflight from a disallowed origin | rejected |

**§8 Ownership:** a pointer table to the sibling skills (OIDC → iac-pipeline, origin lock-down → cloudflare-traffic, Pod Security and signing → gitops-delivery, Access tokens for metrics → observability). No duplication.

### 0.2 Fix cell-services `SKILL.md`

- **Versions table:**
  - Resilience row: `Resilience4j 3.x` becomes `resilience4j-spring-boot4` **2.4.0** plus `spring-boot-starter-aspectj` (Boot 4's new name for starter-aop, required by `@CircuitBreaker`). The version is pinned explicitly because it isn't in the Boot BOM.
  - Gateway row: Spring Cloud **2025.1.3** (`spring-cloud-starter-gateway-server-webmvc`, which supports Boot 4.0.0 up to <4.2.0-M1). The gateway gets circuit breakers through `spring-cloud-starter-circuitbreaker-resilience4j` (BOM-managed) and does not also add `resilience4j-spring-boot4`.
  - Tests row: Testcontainers 2.x via the Boot BOM.
- References line: add `references/security-and-api.md`.
- A short "Admin API and API contract" section that summarises the rules and links to the new file.
- Escrow paragraph: fix the renewal direction (see 0.1 §4).
- Description (now 961 chars): add "admin lease API auth" only if the result stays under 1024 chars with no angle brackets. Otherwise leave it unchanged.

### 0.3 Fix cell-services `references/starter-code.md` (Boot 4 alignment, as approved)

- **pom.xml:**
  - `spring-boot-starter-web` → `spring-boot-starter-webmvc`
  - `resilience4j-spring-boot3` + `${resilience4j.version}` → `resilience4j-spring-boot4` `2.4.0`
  - add `spring-boot-starter-aspectj`
  - `org.testcontainers:postgresql` → `testcontainers-postgresql` and `testcontainers-junit-jupiter`
  - delete the "check the Resilience4j docs" sentence
- **Jackson 3:** imports become `tools.jackson.databind.ObjectMapper`/`JsonMapper`. Replace the "if your build uses Jackson 3" hedge with a definitive statement.
- **Testcontainers 2:**
  - Imports become `org.testcontainers.postgresql.PostgreSQLContainer` (non-generic), matching the generated `TestcontainersConfiguration`.
  - Valkey via `GenericContainer("valkey/valkey:9.0-alpine")` with `@ServiceConnection(name = "redis")`.
- The `LeaseController` comment "NetworkPolicy + service token" becomes a pointer to security-and-api.md. The hardened controller lives there.

### 0.4 Repackage

- Add `tools/skills/package_skill.py` (Python, `zipfile`). It:
  - validates the frontmatter: `name` matches the directory, description is 1024 chars or fewer, no `<` or `>`
  - parses every `yaml`/`json`/`xml` fenced block (PyYAML, json, ElementTree)
  - zips `<name>/SKILL.md` and `<name>/references/*` into `.claude/skills/<name>.skill`
- Rebuild `cloudbridge-cell-services.skill`, which ends up with four entries including `references/security-and-api.md`.
- Update the cell-services row in `.claude/skills/CLOUDBRIDGE_SKILLS_INDEX.md`: references now include `security-and-api.md`, and a changelog line for 2026-10-14 notes the admin auth gap and the Boot 4 fixes.

### 0.5 Install the skills so Claude Code loads them

- Unzip each final `.claude/skills/<name>.skill` into `.claude/skills/<name>/`, which holds `SKILL.md` and `references/`. Cell-services comes from the edited files.
- Delete the nine flat `.claude/skills/cloudbridge-*.SKILL.md` copies (see §1.1).

### 0.6 Patch Rev 2 (keep it the single source of truth)

- Add a "Rev 2.1 changelog (14 Oct 2026)" block under the header.
- Fix §14.2 `hpa.bounds` → `hpa.max`.
- Fix §15.2 formula to `÷ fanout`, plus the maxReplicas inverse and the corrected fanout sentence. Same fix in §29 Q8.
- Replace the §16.2 constraint table and code with the skill's recommender, or a faithful condensed version that points to finops-steering `starter-code.md` §6/§6b.
- §19: add the audited override.
- §B: add rows for Resilience4j and Spring Cloud.
- §25: add an "admin API" row pointing to cell-services `security-and-api.md`.

### 0.7 Repository restructure and dependency alignment

- Move the services with git so history follows:
  - `git mv api-gateway/api-gateway services/api-gateway`
  - same for `order-service` and `inventory-service`
  - remove the now-empty parent directories
- Delete the three Initializr zips and the 20 root initial-skill files (§1.1).
- Order and inventory `pom.xml`: add `resilience4j-spring-boot4` 2.4.0 and `spring-boot-starter-aspectj`.
- All three `TestcontainersConfiguration` files: pin `postgres:18.4-alpine` / `valkey/valkey:9.0-alpine`.
- Deferred, not Phase 0:
  - gateway `jdbc` + driver (Week 1, with `/healthz/cell`)
  - inventory security starters (Week 4, with their config, so nothing is locked down without rules)
- Add a root `.gitignore` covering `target/`, `.terraform/`, `*.tfplan`, `.kube/`, `node_modules/`, `.env`, and `__pycache__/`.

### 0.8 Save this plan

Write it to `docs/IMPLEMENTATION_PLAN.md`: §1 and §3–§6 of this file, plus the build checklist.

### Phase 0 verification

- `python tools/skills/package_skill.py .claude/skills/cloudbridge-cell-services` passes validation.
- `unzip -l` shows the four entries.
- A grep for `resilience4j-spring-boot3|Resilience4j 3|spring-boot-starter-web<|org.testcontainers.containers.PostgreSQLContainer` across `.claude/skills` returns nothing.
- `.claude/skills/*/SKILL.md` has 9 entries, no flat `.SKILL.md` copies remain, and no `cloudbridge-*` files remain at the repo root.
- A grep of Rev 2 finds no `hpa.bounds` and no `× fanout_factor`.
- `services\<svc>\mvnw.cmd -q -DskipTests package` succeeds for all three (proves the pom edits resolve). `tools/dev/test-services.sh` (WSL2 Docker) passes the context-load tests on the pinned images.
- `git status` shows only the intended moves, deletions and edits. No commit until you ask.

---

## 3. Build plan: Weeks 1–8 (MVP weeks 1–6, differentiators weeks 7–8)

The order follows Rev 2 §4.3 and ships first: **a public multi-cloud link by the end of week 2.** For every week, the owning skill's `references/` is the starting code, and acceptance criteria are the "Done when" items.

### Week 1: App, local stack, first VMs (skills: cell-services, gitops-delivery, terraform-cells, ansible-ops)

> **Status (14 Oct 2026): services + local stack done** on branch `week-1-services`.
> - Built: the three services, Flyway V1 schemas, Dockerfiles and `docker-compose.yml`.
> - Tests: 31 Testcontainers tests pass (gateway 11, order-service 9, inventory-service 11). Run them with `tools/dev/test-services.sh`.
> - Local stack: `docker compose up --build` passes all 10 checks in `tools/dev/smoke-local.sh`, end to end through the gateway.
> - The smoke test caught a real bug the tests missed: the gateway's POST retry forwarded an empty body. Fixed by retrying GETs only; `UpstreamProxyIT` now guards it.
> - Deliberate deviations from the skill reference, all now in the skill:
>   - a composite `reservations` key for multi-line orders
>   - release compensation plus a fast-path confirm
>   - gateway routes written in Java
>   - Failsafe for `*IT` tests
>
> **Status (15 Oct 2026): infra half done** on branch `week-1-infra`, all checked offline. Nothing here has touched a real cloud yet.
> - **CI:** `ci-app.yml` builds, tests, scans, signs and publishes the services. `iac-checks.yml` runs the IaC checks on GitHub's runners. Every action is pinned to a commit SHA, and Dependabot keeps the pins current.
> - **Terraform:** the full cell facade plus all implementations. Both budget stacks pass fmt, validate, a 6-run contract test, and an offline plan per stack. Provider lock files are committed.
> - **Ansible:** the four VM roles and `site.yml` pass ansible-lint (production profile) and Molecule (converge, idempotence, verify).
> - Run the checks locally with `bash tools/dev/iac-check.sh`. OpenTofu checks run in CI only: this machine can't reach GitHub's release-asset CDN, which OpenTofu downloads providers from.
> - **Needs real accounts:** state buckets, `make budget-up`, `site.yml` against the live VMs, Docker Hub secrets for `ci-app.yml`, and the GCP OS Login and IAP roles for whoever runs Ansible (Week 5 CI identities).

**Services** (`services/*`, Java 21 records, `JdbcClient`, `RestClient`, virtual threads):

- **order-service:**
  - Migration `V1__orders.sql` (`orders` schema, `uuidv7()` IDs, paise, `currency`, `reservation_id` unique, `idempotency_keys` with status, `outbox` with `attempts`)
  - Classes: `OrderModels` (sealed `Outcome`), `IdempotentOrderService` (claim → reserve → commit), `OrderController`, `InventoryClient` (800 ms / 1.5 s timeouts, `@CircuitBreaker`), `OutboxRelay` (`SKIP LOCKED`, XADD `stream:cell-events`, MAXLEN trim job)
  - Sweeps: O6 and O7
- **inventory-service:**
  - Migration `V1__inventory.sql` (`products`, `inventory_lease` with the `never_oversell` CHECK, `reservations`)
  - Classes: `ReservationService` (I1 single statement, `@ConcurrencyLimit(32)` + `@EnableResilientMethods`), `ReservationReaper` (I3), an `order.created` stream consumer (I2), and the `GET /inventory/{sku}` cache-aside read (I6, `inv:{sku}` with a 30 s TTL plus jitter, breaker falling back to Postgres)
  - The lease admin endpoints come in Week 4 with their security.
- **api-gateway:**
  - WebMVC routes, configured under `spring.cloud.gateway.server.webmvc.routes`:
    - `AddResponseHeader X-CB-Cell`
    - CircuitBreaker
    - Retry for GET and `POST /orders` only
    - a filter that rejects `POST /orders` without the key
  - `CellHealthController` (order readiness + `SELECT 1` as a read-only `health_reader`, Hikari pool 2, 2 s result cache, cache excluded). This step adds `jdbc` + `postgresql` to the gateway pom.
  - Load-shedding semaphore filter, and the rate limiter from security-and-api §5.
  - Public `SecurityFilterChain` (permit public routes, 404 for `/admin/**`).
  - ProblemDetail advice and CORS.
- **Config:** `application.yaml` per service from the skill (Hikari 2 s, `socketTimeout=3`, readiness group excludes redis, metrics tags `cb_cell`/`service`, percentile histograms, `management.server.port: 9080`, graceful shutdown).
- **Tests** (Testcontainers on the pinned images): idempotency (same key → one order; different body → 422), 50 concurrent reservations against a lease of 20 → exactly 20, fencing, health (Valkey down → 200, Postgres down → 503), and outbox at-least-once.

**Local stack:**
- `docker-compose.yml` from gitops-delivery §1. No `version:` key. Pinned images: `postgres:18.4-alpine` (volume at `/var/lib/postgresql`), `valkey/valkey:9.0-alpine`, `prom/prometheus:v3.14.x`, `grafana/grafana:13.2.x`, and k6 behind the `load` profile.
- `services/*/Dockerfile`: layered jar, UID 10001, `ExitOnOutOfMemoryError`.

**CI:** `.github/workflows/ci-app.yml` (matrix build with `./services/<svc>/mvnw verify`, buildx with SBOM and provenance, Trivy, cosign keyless, per-service `digest-<svc>.env`). Every action is pinned by commit SHA.

**Infra:**
- `infra/live/_shared/versions.tf`
- `infra/modules/network/{aws,gcp}`
- `infra/modules/cluster/{k3s-vm-aws,k3s-vm-gcp}`: VM, static IP, firewall allowing 443 from Cloudflare only; SSM instance profile / IAP 22; tags `cb-ansible-role=k3s_server`
- `infra/modules/cell` facade with `shapes.tf`
- `infra/live/{aws,gcp}-budget/10-foundation` (S3 `use_lockfile` / GCS backends)
- `infra/Makefile` with `budget-up`

**Ansible:**
- `ansible/requirements.yml`, `ansible.cfg`, `inventories/{aws_ec2,gcp_compute}.yml`, `group_vars/cloud_{aws,gcp}.yml` (SSM / IAP)
- Roles: `base_hardening`, `k3s_server` (v1.36.x+k3s1, Traefik disabled), `node_exporter`, `registries_mirror`
- Molecule + `ansible-lint --profile production`

**Done when:**
- `docker compose up` serves `POST /orders` end to end.
- `make budget-up` creates both VMs.
- `site.yml` installs k3s.
- The Molecule scenarios are green.

### Week 2: Live multi-cloud link (skills: cloudflare-traffic, ansible-ops, gitops-delivery)

> **Status (15 Oct 2026): repo side done** on branch `week-2-gitops-traffic`, checked offline. Nothing has touched a real cloud or Cloudflare yet.
> - **Gitops:** a `cb-service` library chart and three thin service charts, `platform-addons` (default-deny NetworkPolicies, Argo Rollouts and Traefik as pinned child Applications, budget Postgres/Valkey), the root ApplicationSet template, global + per-cell values, and ring files holding the digests `main` published on 15 Oct. `iac-check.sh gitops` renders every chart for both cells; kubeconform validates all 60 resources.
> - **Release flow:** `ci-app.yml` opens a `ring-canary` release PR after each `main` build (`tools/bump_ring.py`).
> - **Ansible:** `cell_secrets`, `origin_tls` and `argocd_autodeploy`, plus the `/healthz/cell` smoke test in `site.yml`. Lint-clean on the production profile; Molecule covers converge, idempotence and verify.
> - **Terraform:** `global/20-origin-tls` (Origin CA certificate into both secret managers) and `global/30-traffic` (load balancer, monitor, pools, admin records, Cloudflare Access) with offline stack tests. This machine can't download the Cloudflare provider, so those two stacks validate only in CI.
> - **Deviations from the plan text:** Argo CD 3.5 (current) instead of 3.3. Canary analysis is off until Week 5's in-cell Prometheus. Budget cells get resource overrides. The Origin CA certificate has its own stack, so the traffic stack stays Cloudflare-only.
> - **Needs real accounts:** follow [the go-live runbook](runbooks/week-2-go-live.md) (Cloudflare zone and Load Balancing, state buckets, pull-token secrets, `make budget-up`).

- **Traffic stack** `infra/live/global/30-traffic`:
  - monitor (`/healthz/cell`, 60 s, retries 2, `SAS`/`SEAS`)
  - two pools (`for_each`)
  - LB with `random_steering.pool_weights`, cookie affinity, `zero_downtime_failover=sticky`
  - `terraform.tfvars.json` with `{aws:70,gcp:30}`, validated (sum 100; each 0 or ≥ 10)
  - state in GCS
  - **plus** `admin-<cloud>` proxied DNS records, a Cloudflare Access application and service token, and a Service Auth policy (from security-and-api §3)
- **Origin lock-down:** `cloudflare_ip_ranges` passed into each cell; Origin CA cert with Full (strict).
- **Ansible:**
  - `origin_tls`
  - `argocd_autodeploy`: k3s `HelmChart` for Argo CD 3.3, plus the root ApplicationSet rendered with `cell`/`ring` and the `ignoreDifferences` on `/spec/minReplicas`
- **Gitops:**
  - `gitops/charts/{api-gateway,order-service,inventory-service,platform-addons}`: probes, HPA, PDB, spread, restricted security, default-deny NetworkPolicy, plus an in-cluster Postgres/Valkey StatefulSet for budget
  - `gitops/cells/cb-{aws,gcp}-budget/values.yaml`
  - `gitops/releases/ring-{canary,main}.yaml`
- **Done when:** `https://app.<domain>` is live, and `curl -sI` run repeatedly shows `X-CB-Cell` from both clouds.

### Week 3: Managed profile (terraform-cells, iac-pipeline)

> **Status (16 Oct 2026): repo side done** on branch `week-3-managed-profile`, checked offline. No cluster has been created yet; that needs the accounts from the Week 2 runbook.
> - **Facade:** new inputs `managed_data`, `expires_at` (`cb-expires-at` label), `admin_principal_arns`, `image_mirror`. One `terraform_data.guards` enforces the cross-variable rules:
>   - managed cells need `admin_cidrs`, and never `0.0.0.0/0`
>   - budget cells need Cloudflare's ranges
>   - prod never expires
>   - an expiring cell can't own `prevent_destroy` data services
>
>   `cell` also gains `image_mirror` and `expires_at`.
> - **EKS:** cluster-admin access entries; the EBS CSI driver and AWS Load Balancer Controller (v3.6.0 policy) via Pod Identity; pull-through permissions on the node role.
> - **GKE:** `auth.project` added to its output.
> - **Registry mirrors:** `registry-mirror/aws-ecr-ptc` and `registry-mirror/gcp-ar-remote`.
> - **Ephemeral stacks:** `live/{aws,gcp}-dev/10-foundation`, with `make managed-up | managed-check | managed-down | reap`.
> - **Workflows:** `global/00-ci-identity` holds the `ephemeral` environment's OIDC/WIF identities only (Week 5 adds plan/apply roles). `ephemeral-up.yml` and `ttl-reaper.yml` both call `tools/dev/reap-expired.sh`, which reads the expiry from state.
> - **Tests:** contract test 14/14 (4 implementations, 2 ephemeral applies, 6 guard rejections, azure); dev and CI-identity stack tests pass. OpenTofu runs in CI.
> - **Deviation:** the managed `20-bootstrap` (Argo CD by Terraform, cell values, ingress controller and health checks, External Secrets) moves to Week 4, which builds the data and secrets it needs. Runbook: [week-3-ephemeral-managed.md](runbooks/week-3-ephemeral-managed.md).

- Modules `cluster/aws-eks` (API auth mode, access entries, `public_access_cidrs`, STANDARD support, Pod Identity) and `cluster/gcp-gke` (zonal, REGULAR, Dataplane V2, private nodes, least-privilege SA, Workload Identity).
- `registry-mirror/{aws-ecr-ptc,gcp-ar-remote}`.
- `tests/contract.tftest.hcl` covering 4 implementations plus the azure rejection; run on Terraform 1.15 and OpenTofu 1.12.
- `ephemeral-up.yml` + `ttl-reaper.yml` (`cb-expires-at`, at most 8 h).
- **Done when:** `make managed-up CLOUD=gcp` yields a healthy cluster that gets reaped after its TTL.

### Between Weeks 3 and 4: local two-cell twin (gitops-delivery, ansible-ops)

> **Status (1 Nov 2026): runs end to end** on branch `local-twin`, at $0 and with no cloud account. Runbook: [local-twin.md](runbooks/local-twin.md).
> - **What it is:** `tools/dev/twin.sh` runs `cb-aws-local` and `cb-gcp-local` (k3s v1.36 containers) built by the budget roles via `ansible/playbooks/twin.yml`. A Traefik edge, generated from `terraform.tfvars.json` by `tools/dev/twin/edge_config.py`, reproduces the Cloudflare LB's weights, cookie, monitor, fallback and Full strict. Argo CD follows a snapshot of the working tree.
> - **Measured:** a 70/30 split (140/60 of 200), cookie affinity, and the API smoke tests pass. Failover took 18 s with AWS down and 14 s with GCP down; each cell was back 1 s after it returned.
> - **Found:** the root ApplicationSet needs `ServerSideDiff=true`, which is fixed for all cells.
> - **Why now:** Weeks 4–8 (allocator across two cells, parity checker, Prometheus/Grafana, drills, Rollouts) can be built against it before the real go-live. Cloud APIs, Cloudflare's API and Access, and real failover timing still need the clouds.

### Week 4: Data and cells (terraform-cells, cell-services)

- `database/{aws-rds,gcp-cloudsql}` (PG 18, `prevent_destroy`, `random_password` → secret store, `secret_ref` output).
- `cache/{aws-elasticache,gcp-memorystore}` (Valkey 9.0), with the `managed_cache` toggle.
- ESO `SecretStore` per cloud.
- **Lease admin API:**
  - hardened `LeaseController`
  - inventory security starters + config
  - `V2__lease_audit.sql` (expand only: `lease_grant_log`, `products.max_cell_grant`)
  - roles migration (`order_svc`, `inventory_svc`, `parity_reader`, `health_reader`)
- **Lease allocator** (new; Rev 2 §23.3):
  - Lives in `control-plane/allocator/` (Python 3.14). Control-plane tables `stock(sku, total_qty)` and `lease_grants(cell_id, sku, epoch, granted_qty, expires_at, reported_sold, at)`.
  - Every 5 min it GETs `/admin/leases/report` from each cell and grants `floor(remaining × w_cell × 0.9)` with `epoch+1` and a 15-min TTL.
  - If a cell is unreachable, it waits `expires_at + 60 s` before re-granting that cell's quantity elsewhere.
  - Authenticates with the Access service token.
  - Unit tests: sum of grants ≤ stock; no regrant before expiry + margin.
- **Done when:** an order survives pod restarts; a duplicate POST with the same key returns the same order; and a forged grant without a token gets a 401/404 from outside.
- **Status (2 Nov 2026):** "done when" verified on the local twin (`tools/dev/twin.sh leases`, results in `docs/runbooks/local-twin.md`), not on a cloud. What changed from the plan above:
  - **Grant contract.** Grants carry `reportedSold` and answer `grantedQty`, and the cell computes `GREATEST(sold_qty, reportedSold + remainingQty)`. A randomized allocator test oversold without them: sales after the report were added on top of the grant, and a cell that sold past a shrink kept those sales while the other cell was granted as if it hadn't.
  - **Names.** The migration is `V2__lease_admin_hardening.sql`. The Access AUD is one per zone (one Access application in `30-traffic`), delivered in the `cell-admin` Secret.
  - **Cells sell nothing until granted.** `R__catalog.sql` seeds products everywhere; only the `local` profile seeds leases. The allocator's real-cloud deployment is the control-plane VM (Week 6), so **once these images are released, real cells refuse orders until then**, and they need `cell-admin`, or the gateway and inventory-service refuse to start.
  - **Go-live order.** `30-traffic` now applies before `make configure`, because the cells need its Access audience. Budget cells have `replicas.max: 1` (see the twin runbook).
  - **Not wired.** Migrations create `order_svc`, `inventory_svc`, `parity_reader` and `health_reader` without passwords. Services still use the owner credentials.
  - **Never run on a cloud.** RDS, Cloud SQL, ElastiCache, Memorystore, External Secrets, `20-bootstrap`, the ALB and GCE ingress, and real Access JWTs (claim names included). The TTL reaper destroys only `10-foundation`, so an ALB left by `20-bootstrap` could block a VPC destroy. The AWS managed origin for `30-traffic` is still set by hand.
  - **Known limit, a product decision.** After expiry + margin an unreachable cell counts only its last-reported sold. If just the allocator was partitioned and the cell kept selling until expiry, the total can exceed stock by those sales; `STOCK OVERRUN` is logged when the cell returns. The strict alternative is never to re-grant until the cell reports, which strands stock for the whole outage.

### Week 5: CI/CD hardening and observability (iac-pipeline, observability-dashboard)

- `global/00-ci-identity` (OIDC roles: plan read-only, apply per environment; WIF with attribute conditions).
- `_terraform-stack.yml` (saved-plan apply, `concurrency`, `-lockfile=readonly`), `iac-pr.yml` (one sticky comment), `iac-apply.yml`, `drift.yml`. (`iac-engines.yml` was dropped: `iac-checks.yml` already runs every stack on both engines.)
- tflint, Trivy config and Conftest (`infra/policy/*.rego`); Infracost diff.
- Prometheus agent in cells → `remote_write` through Access → central receiver.
- Recording and alert rules (`cb:*`, `CellSLOBurnFast/Slow`, `ExitPlanEvidenceStale`, `CostDataStale`), Alertmanager, blackbox.
- Grafana with five provisioned dashboards.
- k6 load test that writes the measured per-pod RPS into `gitops/cells/<cell>/capacity.yaml`.
- **Done when:** a PR shows both plans, the cost delta and the policy result in one comment.
- **Status (3 Nov 2026):** observability verified on the local twin (results in `docs/runbooks/local-twin.md`). The pipeline is built and checked offline. **"Done when" is not yet met on a real PR:** the comment is proven by unit tests on fixtures, and until the identities exist a real PR shows "not planned" and "not measured". Switch-on list: [iac-pipeline.md](runbooks/iac-pipeline.md). What changed from the plan above:
  - **No `iac-engines.yml`.** `iac-checks.yml` already runs every stack on both engines.
  - **Pipeline stacks.** `aws-budget/10-foundation`, `gcp-budget/10-foundation` and `global/30-traffic`. `*-dev`, `00-ci-identity` and `20-origin-tls` stay out, for the reasons in the runbook.
  - **Pulled forward from Week 6.** `control-plane/migrations/` (V1 to V6 from the finops skill, plus `V7__roles.sql`), so dashboards read real, empty tables.
  - **Deferred.** The central stack's real deployment, the `metrics.<domain>` Access application, DNS and service token (with the control-plane VM, Week 6). The Cloudflare analytics exporter is not built: the observed split is what the origins saw. Real cells keep `observability.enabled: false` until then.
  - **Canary analysis.** Week 7 will query the central Prometheus with a `cb_cell` filter, since a query-capable Prometheus doesn't fit a 2 GiB cell.
  - **Traefik limit raised from 128 to 256 MiB, on budget cells too.** k6 found that the old limit takes the whole ingress down at 40 RPS. With the agent's 128 MiB, a 2 GiB VM gets tighter, and that is still unmeasured on a real VM.
  - **Capacity.** `gitops/cells/cb-*-local/capacity.yaml` hold twin numbers. `cb-*-budget` stay at 0, so the capacity check keeps refusing to evacuate there until k6 runs against a real VM.
  - **Never run on a cloud.** OIDC and Workload Identity trust, the apply identities' permissions, saved-plan applies, Infracost (needs a key) and Conftest on a real `plan.json`.

### Week 6: D1 parity and D4 cost ledger (parity-contract, finops-steering, observability-dashboard)

- **D1:**
  - `parity/contract.yaml` (12 checks including `hpa.max`) and `exceptions.yaml` (`patch-only`, `ring-window`, with expiry)
  - `control-plane/parity-checker` (engine where unknown never counts as a match; `AwsManagedFacts`/`GcpManagedFacts`/`K3sFacts`; CLI)
  - `parity.yml` (nightly + post-sync); `evals/parity` gate
- **D4:**
  - control-plane schema V1 (finops-steering `schema-and-queries.md`, partitions)
  - `cost-collector` (AWS FOCUS 1.2 Parquet, parameterised GCP BigQuery FOCUS view, idempotent writer, OpenCost + Prometheus pullers)
  - FastAPI `control-plane/api` (capacity with `÷ fanout`, drills, traffic-changes, parity snapshots, bearer + Access)
  - Next.js 16.3 dashboard `/`, `/cost`, `/parity`, each with an "as of" timestamp
- **Done when:** the parity score is visible, and changing a chart version in one cell fails CI.
- **Status (3 Nov 2026):** "done when" verified on the local twin and in the offline checks (`tools/dev/twin.sh parity`, `twin.sh cost`, `tools/dev/iac-check.sh parity`; results in `docs/runbooks/local-twin.md`). A chart version changed in one cell fails `iac-checks.yml`'s parity job (score 0.842) and the live check (0.914), and the score shows on the dashboard. No real cell or bill has been read. What changed from the plan above:
  - **Thirteen checks, not twelve.** `k3s.version` joins the contract; `parity/cells.yaml` skips what doesn't apply to an environment, each with its reason. `parity/exceptions.yaml` holds only `ring-window`: a `patch-only` exception is added when a real patch difference exists, with its expiry.
  - **`AwsManagedFacts` and `GcpManagedFacts` have run only on fixtures** (`evals/parity`, unit tests). Only `K3sFacts` has read real cells, and those are the twin's. `parity.yml` reports "not measured" until `CB_PARITY_ENABLED` is set, and how it reaches real cells is added with the first one.
  - **Not wired.** The Argo CD notification that sends `repository_dispatch` (`argocd-synced`): `parity.yml` accepts it, and no cell sends it yet.
  - **The ledger has run only on sample files**, in a scratch database. The real AWS export and the BigQuery view have only seen stand-ins. The twin's own ledger stays empty, so panels say "no measurement yet" and `CostDataStale` fires. OpenCost isn't deployed in any cell: its puller is tested on a fixture, and until it runs shared cost has no share to divide by, which the dashboard shows.
  - **The API and the dashboard.** Next.js is at 16.3.8. `GET /drills/latest/report.md` and `/evacuation-proposal` come with their callers in Weeks 7 and 8. Dashboard pages beyond `/`, `/cost` and `/parity` aren't built.
  - **Deferred again (see Week 5).** The control-plane VM, the real deployment of the central stack, API, dashboard and allocator, and the `metrics.<domain>` and `cp.<domain>` Access applications. They aren't in this week's list, and need the accounts.

### Week 7: D2 evacuation and D5 cloud canary ring (ansible-ops, gitops-delivery)

- Playbooks `prewarm.yml`, `evacuate.yml` (record → capacity ≥ 1.2 → pre-warm → steps 50/25/0 with a 150 s wait → burn > 6 or p95 > 600 ms aborts → rescue compensation → report), `failback.yml`, `drill.yml`, and `propose_evacuation.yml`.
- `tools/cf_break_glass.py`.
- `.github/workflows/drill.yml`.
- Argo Rollouts canary 10/50/100 with an `AnalysisTemplate`.
- `tools/bump_ring.py` and `ring-promote.yml` (30-min soak, burn < 1, p95 within 10%).
- **Done when:** a drill report in `docs/drills/` shows the measured shift time and errors.

### Week 8: D3 steering, D6 plan-risk, EDA, polish (finops-steering, iac-pipeline, ansible-ops)

- **D3:** the skill's `recommender.py`, `weekly.py` with `last_direction`, and an `evals/steering` backtest (6 scenarios including no oscillation) gating `evals.yml`. Output is a PR on `terraform.tfvars.json` only.
- **D6:** `control-plane/plan-risk` rules and CLI, `evals/plan-risk` (60 plans, block recall = 1.0, precision ≥ 0.90), the audited `allow-destructive` override, and an optional LLM explainer behind the adapter.
- **EDA:** `rulebooks/cell-degraded.yml` with throttle. Prod only ever proposes.
- **D7:** budget and managed profiles behind one interface (already delivered in weeks 1–3; verified by the contract test).
- **D8:** `docs/leaky-abstractions.md` (12 rows), `docs/scaling-decisions.md`, ADRs.
- **README** per Rev 2 §28, with live numbers only.
- **Cut line** (Rev 2 §4.4), dropped in this order: LLM explainer → EDA → automated ring promotion → recommender automation → managed Valkey. **Never cut:** the live link, the parity check, one drill report, and the cost-per-request panel.

---

## 4. Differentiator map

| ID | Feature | Week | Skill | CI gate |
|---|---|---|---|---|
| D1 | Cross-cloud parity score | 6 | parity-contract | 0 missed divergences |
| D2 | Capacity-verified, SLO-gated evacuation with a drill report | 7 | ansible-ops | drill freshness < 14 d |
| D3 | Cost-based steering recommender (PR, not autopilot) | 8 | finops-steering | backtest: 0 SLO violations, 0 reversals |
| D4 | FOCUS ledger with fairness rules | 6 | finops-steering | freshness < 72 h |
| D5 | Cloud as canary ring | 7 | gitops-delivery | parity `ring-window` ≤ 2 h |
| D6 | Plan-risk gate (rules first) | 8 | iac-pipeline | block recall 1.0 |
| D7 | Managed and budget profiles behind one interface | 1–3 | terraform-cells | contract test on both engines |
| D8 | Leaky-abstraction register | 8 | terraform-cells | — |

## 5. Prerequisites on Windows 11 (check before Week 1)

- **Docker:** no Docker Desktop on Windows; Docker Engine 29.x runs in the WSL2 distro `Ubuntu-D` (on the D: drive). Run tests with `MSYS_NO_PATHCONV=1 wsl -d Ubuntu-D -- bash "/mnt/d/New Projects/Cloud_Bridge/tools/dev/test-services.sh"`. It runs Maven in a throwaway `maven:3-eclipse-temurin-21` container that uses the WSL Docker socket (so WSL needs no Java), with `TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal`. Run Compose inside WSL too (`docker compose up` from `/mnt/d/...`).
- **Terraform 1.15.x and OpenTofu 1.12.x.**
- **Ansible:** ansible-core 2.21 doesn't support Windows as a control node, so use **WSL2 Ubuntu 24.04**, or run it only from GitHub Actions runners (which the plan already does for drills).
- **Cloud accounts:** AWS with budgets at 50/80/100% and GCP with a billing budget, both from day 1. Cloudflare Load Balancing add-on (about US$5/month).
- **Re-verify on build day:** the Google/Helm/Kubernetes provider majors, Cloudflare v5 nested attribute names, Access JWT claim names (`common_name`), and the exact Prometheus/Grafana/k6 patch versions.

## 6. Risks specific to execution

- Skill starter code was syntax-checked but has never been compiled against Boot 4.1. Week 1 is the first real compile, so expect small API fixes (the WebMVC gateway filter args, Spring Security 7 DSL). When a fix lands, patch the skill too, then repackage with `package_skill.py`.
- Keep idempotency strictly cell-scoped and document the cross-cell duplicate window. Don't claim exactly-once across clouds.

## Verification (end to end, per phase)

- **Phase 0:** see "Phase 0 verification" above.
- **Each week:** that week's "Done when" checks, plus `tools/dev/test-services.sh` (WSL2 Docker), `terraform fmt -check` / `validate` / `test` on both engines, `ansible-lint` + Molecule, and the eval gates in `evals.yml` once they exist.
