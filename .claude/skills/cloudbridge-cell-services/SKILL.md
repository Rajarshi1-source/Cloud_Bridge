---
name: cloudbridge-cell-services
description: Write CloudBridge's Spring Boot 4.1 / Java 21 / Maven microservices so they behave as independent cells on AWS and GCP - api-gateway (routes, rate limiting, /healthz/cell aggregate, X-CB-Cell header, load shedding), order-service (uuidv7 IDs, money in paise, Idempotency-Key saga, transactional outbox to Valkey Streams) and inventory-service (escrow leases with fencing epochs so two cells never oversell). Covers the per-cell PostgreSQL 18 schema, Flyway expand-contract migrations, Resilience4j timeouts, circuit breakers and retries for idempotent calls only, bulkheads, Testcontainers tests, JVM flags for 2 GiB VMs and the admin lease API auth (Cloudflare Access JWT). Use for ANY Java or SQL work in services/, or questions about cross-cloud data consistency, read-your-writes, overselling, idempotent APIs or health endpoints for Cloudflare, even without naming Spring. MANDATE - no synchronous cross-cloud calls on the request path; cache never in /healthz/cell. Not for Helm or Argo (gitops-delivery).
---

# CloudBridge — Cell Services

Each cloud runs a **cell**: its own gateway, services, Postgres and Valkey. Cells never call each other on the request path. That single rule is what makes a cloud outage survivable — and it forces three design decisions the code must get right: where a user's data lives (home cell), how retries stay safe across failover (idempotency), and how two cells sell from one stock pool without a distributed transaction (escrow leases).

References: `references/schema-and-queries.md` (Flyway migrations + the exact SQL the services run), `references/starter-code.md` (pom, application.yml, key classes, tests) and `references/security-and-api.md` (route list, admin lease API auth, grant bounds, Idempotency-Key / ProblemDetail / rate-limit / CORS contract).

## Versions and build

| Component | Pin |
|---|---|
| Spring Boot | 4.1.x (floating patch; 4.0 leaves OSS support 31 Dec 2026) on Spring Framework 7 |
| Java | 21 LTS (virtual threads on) |
| Build | Maven wrapper (`./mvnw`), matching the Dockerfile and your other Spring capstones |
| Gateway | Spring Cloud **2025.1.3** (supports Boot 4.0.0 up to, not including, 4.2.0-M1): `spring-cloud-starter-gateway-server-webmvc` (servlet flavour, not Reactive Gateway); circuit breakers via `spring-cloud-starter-circuitbreaker-resilience4j` (BOM-managed — don't also add `resilience4j-spring-boot4` to the gateway) |
| Resilience | `io.github.resilience4j:resilience4j-spring-boot4` **2.4.0** + `spring-boot-starter-aspectj` (Boot 4's name for the old starter-aop; `@CircuitBreaker` needs it) in order- and inventory-service. Not in the Boot BOM yet, so the version is pinned explicitly. There is no Resilience4j 3.x and `resilience4j-spring-boot3` is for Boot 3 — never use it. Bulkheads/retries on plain methods use Spring Framework 7's built-in `@ConcurrencyLimit` / `@Retryable` |
| DB / cache drivers | PostgreSQL JDBC + Flyway; Lettuce (Valkey speaks the Redis protocol, so Spring Data Redis works unchanged) |
| JSON | Jackson 3 (`tools.jackson.*`) — Boot 4's default; don't import `com.fasterxml.jackson.databind` |
| Web starter | `spring-boot-starter-webmvc` (Boot 4 name; `spring-boot-starter-web` is the old one) |
| Tests | JUnit 5, Testcontainers 2.x via the Boot BOM (`testcontainers-postgresql`, `testcontainers-junit-jupiter`; `org.testcontainers.postgresql.PostgreSQLContainer`), images pinned `postgres:18.4-alpine` and `valkey/valkey:9.0-alpine` — never `:latest` |

## Cell identity

`CB_CELL` env var (e.g. `cb-gcp-prod`). The gateway adds `X-CB-Cell: <cell>` to every response — the live demo uses it to show both clouds serving traffic, and it's invaluable when debugging affinity. Orders store `cell` as provenance.

## Health endpoints (Cloudflare drains on these)

| Endpoint | Meaning | Includes |
|---|---|---|
| `/actuator/health/liveness` | Process alive | nothing external |
| `/actuator/health/readiness` | This pod can serve | own DB pool for DB-backed services |
| `/healthz/cell` (gateway) | **This cell can take orders** | gateway ready + order-service readiness (HTTP, 500 ms timeout) + cell DB `SELECT 1` |

The cache is **not** in `/healthz/cell`. A cold or failed Valkey degrades latency; it must not drain the whole cloud. Health checks also must not trigger cascading failures: cache the composite result for 2 s so Cloudflare's probes from several regions don't hammer the DB.

## Orders (order-service)

- IDs: `id uuid PRIMARY KEY DEFAULT uuidv7()` generated **in Postgres 18** (time-ordered, no coordination, mergeable across cells if history is ever replicated). Don't generate order IDs with `UUID.randomUUID()` (v4, random order, worse index locality); tests may use random UUIDs for idempotency keys and customers only. Show the column definition whenever you write order persistence code.
- Money: `bigint` paise. Never `double`, never `numeric` in JSON payloads without a currency field.
- `POST /orders` requires `Idempotency-Key` (client-generated UUID). Never hold a DB transaction open across an HTTP call, so the flow is a small saga:
  1. **Claim** — insert `idempotency_keys(key, request_hash, status='PENDING')`. Conflict: `COMPLETED` → return the stored response; `PENDING` → 409 "in progress, retry"; same key + different body hash → 422.
  2. **Reserve** — `POST inventory/reservations` with `reservation_id = Idempotency-Key`. Inventory inserts the reservation and decrements its lease in one transaction; a repeat with the same id returns the original result.
  3. **Commit** — one transaction: insert order + items + outbox `order.created` (carrying `reservation_id`) and set the key `COMPLETED` with the response.
  4. **Failure paths** — a line out of stock, or inventory timing out → `POST /reservations/{id}/release` (compensation, best effort) and key `FAILED`; the client may retry with the same key, and a released line is reserved afresh. Commit fails after reserve → key `FAILED`, the reservation stays `HELD` for the retry (reserve replays), and inventory's reaper releases it after 15 min if no retry comes.
  5. **Confirm** — right after commit, `POST /reservations/{id}/confirm` (fast path); the `order.created` event is the durable path. Both are needed: if a HELD line outlives the reaper window while its order exists, the cell can sell that unit twice.
- Each service owns its own schema in the cell database (`orders`, `inventory`); no service reads another's tables.
- Outbox: `outbox` rows written in the same transaction as the state change; a relay polls with `FOR UPDATE SKIP LOCKED`, publishes to Valkey Stream `stream:cell-events` (`XADD … MAXLEN ~ 100000`), marks `published_at`. At-least-once — consumers dedupe on event id.

## Inventory escrow (inventory-service)

The global invariant is "never sell more than total stock". Cells can't coordinate synchronously, so the control-plane allocator grants each cell a **lease**: `granted_qty`, `lease_epoch` (fencing token), `expires_at` (15 min). Inside a cell:

```sql
UPDATE inventory_lease
   SET sold_qty = sold_qty + :qty
 WHERE sku = :sku AND expires_at > now() AND sold_qty + :qty <= granted_qty
RETURNING granted_qty - sold_qty AS remaining;      -- 0 rows → 409 OUT_OF_STOCK_IN_CELL
```
One statement, no read-modify-write race; `CHECK (sold_qty <= granted_qty)` backs it up. The cell never calls out: every 5 min the allocator reads `GET /admin/leases/report` (`sold_qty` per SKU) and re-grants with `POST /admin/leases/grant` carrying `epoch + 1`. A renewal or grant carrying an **older epoch is rejected** — that's the fence that stops a zombie cell (partitioned, clock-skewed) from overwriting a newer grant. When a lease expires the cell stops selling that SKU by itself; the allocator waits `expires_at + 60 s` before re-granting the unsold quantity elsewhere.

Trade-off to state plainly: **never oversells, may briefly undersell** (stock stranded in an unreachable cell until its lease expires).

## Admin lease API and API contract

`POST /admin/leases/grant` decides how much a cell may sell, so it is the endpoint that can break "never oversell". A NetworkPolicy can't protect it — the allocator on the GCP VM reaches the AWS cell through Cloudflare like any user — and the Cloudflare IP allowlist only proves "from Cloudflare", not "from me". Rules (full code and tests in `references/security-and-api.md`):

- Admin routes live only on a per-cell hostname `admin-<cloud>.<domain>` (proxied straight to that origin, not the LB); `/admin/**` on the public host returns 404.
- Cloudflare Access (service token) at the edge **and** the `Cf-Access-Jwt-Assertion` JWT validated at the origin — issuer, AUD tag, expiry, allowlisted `common_name` → `ROLE_LEASE_ALLOCATOR` — in the gateway **and again** in inventory-service. Missing config fails start-up (fail closed).
- Even an authenticated grant is bounded: fencing (`epoch > current`), epoch jump ≤ 1000, TTL ≤ 20 min, quantity ≤ `max_cell_grant`; same `(sku, epoch)` replays return 200; every attempt is written to `inventory.lease_grant_log`.
- Public contract: `Idempotency-Key` UUID (cell-scoped — say so), RFC 9457 `ProblemDetail` with stable `type` slugs, `RateLimit-*` + `Retry-After` on 429, 503 + `Retry-After: 2` on shedding, CORS only for the dashboard origin, actuator on management port 9080.

## Resilience defaults

| Concern | Setting |
|---|---|
| Timeouts | gateway route 2 s; HTTP clients connect 800 ms / read 1.5 s; JDBC `socketTimeout=3`, Hikari `connectionTimeout=2000` |
| Circuit breakers | gateway→order, gateway→inventory, order→inventory, services→Valkey: 50% failure over 20 calls, 30 s open, half-open 5 |
| Retries | gateway retries **GETs only** (max 2, exponential backoff). `POST /orders` is retried by the **client** under the same Idempotency-Key — the gateway's Retry filter needs body caching for POST, and with it the upstream received an **empty body** (caught by `UpstreamProxyIT` + the compose smoke test) |
| Bulkheads | separate executors for DB-bound and cache-bound work; `@ConcurrencyLimit` on DB-heavy endpoints |
| Load shedding | gateway rejects with 503 + `Retry-After: 2` when in-flight > limit; `/healthz/cell` stays green (shedding is graceful degradation, not failure) |
| Cache failure | inventory reads fall back to Postgres (breaker open); rate limiter falls back to a local token bucket |

## Migrations: expand → migrate → contract

Two cells can run adjacent app versions for up to two hours (canary ring). Every Flyway migration must work with the **previous** app version: add nullable columns / new tables first (expand), backfill (migrate), and only drop or tighten in a later release after both rings run the new code (contract). The parity contract compares `flyway_schema_history` max version across cells.

## JVM on small nodes

Managed: `-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError`. Budget (2 GiB VM, one replica each): add `-XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xss512k`, Hikari pool 5, Tomcat/virtual threads. GraalVM native images are the stretch option for the budget profile.

## Tests that prove the cell properties

1. Idempotency: same key twice → one order, identical response; same key different body → 422.
2. Concurrency: 50 parallel reservations against a lease of 20 → exactly 20 succeed (Testcontainers Postgres).
3. Fencing: renewal with epoch N−1 after epoch N → rejected.
4. Health: Valkey container stopped → `/healthz/cell` still 200; Postgres stopped → 503.
5. Outbox: crash between commit and publish (kill relay) → event published after restart, exactly once per consumer after dedupe.

## Interview soundbites

- "Cells never call each other on the request path — that's what makes losing a cloud survivable."
- "Inventory uses escrow leases with a fencing epoch: we may briefly undersell, we can never oversell."
- "The cache isn't in my cell health check — a cold cache should cost latency, not a whole cloud."
