# Cell Services — Security & API Contract

Covers the cell's HTTP surface: which routes exist on which hostname, how the admin lease API is authenticated, how grants are bounded even after auth passes, and the public API contract (Idempotency-Key, ProblemDetail errors, rate-limit headers, load shedding, CORS).

The sibling skills own their own security; don't duplicate it here:

| Concern | Owner |
|---|---|
| CI → cloud (GitHub OIDC, WIF, plan/apply roles) | cloudbridge-iac-pipeline |
| Origin lock-down to Cloudflare ranges, Origin CA, Full (strict) TLS, Access app + service token **resources** in Terraform | cloudbridge-cloudflare-traffic |
| Pod Security, NetworkPolicy manifests, image signing, digests | cloudbridge-gitops-delivery |
| Access service tokens for metrics `remote_write` and the control-plane API bearer | cloudbridge-observability-dashboard |
| **Admin lease API auth, grant bounds, public API contract** | **this file** |

## Contents
1. Threat model — the gap this file closes
2. Route list — two hostnames per cell
3. Admin authentication — Cloudflare Access JWT validated at the origin
4. Grant semantics — bounds that hold even when auth passes
5. API contract — Idempotency-Key, errors, rate limits, shedding, CORS, limits
6. Code — gateway security, problem catalog, filters, hardened lease API, migration
7. Tests

---

## 1. Threat model

`POST /admin/leases/grant` sets how much stock a cell may sell. It is the single most dangerous endpoint in the cell:

- **The caller is cross-cloud.** The lease allocator runs in the control plane on the GCP budget VM. To reach the AWS cell it goes through Cloudflare, exactly like a user. A Kubernetes NetworkPolicy sees "traffic from the ingress controller" in both cases and cannot tell them apart.
- **Origin lock-down is not authentication.** The origin accepts 443 only from Cloudflare's IP ranges, but those ranges are shared by every Cloudflare customer. Anyone can put their own Cloudflare zone in front of your origin IP. "From Cloudflare" never means "from me".
- **A forged grant breaks the core invariant.** A stranger who posts `{remainingQty: 1000000, epoch: 9e18}` either inflates `granted_qty` (the cell oversells real stock) or plants an epoch so high that every real allocator grant is fenced as stale forever. Both break "never oversell".

So the endpoint needs three independent controls: **authentication** (only the allocator's identity), **authorization** (only the lease role, only on the admin hostname), and **semantic bounds** (a valid caller still can't send an absurd grant).

## 2. Route list

Each cell has two hostnames:

| Hostname | DNS | Purpose |
|---|---|---|
| `app.<domain>` | Cloudflare Load Balancer (70/30, cookie affinity) | Public API |
| `admin-<cloud>.<domain>` (e.g. `admin-aws`, `admin-gcp`; `admin-aws-dev` per env) | Proxied record pointing **directly** at that cell's origin, not the LB | Allocator → one specific cell |

The admin hostname must bypass the LB because the allocator has to reach one particular cell; random steering would deliver a grant to whichever cell the dice picked. One DNS label (`admin-aws`, not `admin.aws`) keeps it under Cloudflare's Universal SSL certificate.

| Host | Method + path | Upstream | Auth | Notes |
|---|---|---|---|---|
| app | `GET /healthz/cell` | gateway (local) | none | Cloudflare monitor; composite result cached 2 s; never rate limited or shed |
| app | `POST /orders` | order-service | none (public demo) | `Idempotency-Key` required → else 400 at the gateway |
| app | `GET /orders/{id}` | order-service | none | Cell-local: 404 if the order lives in another cell (read-your-writes comes from affinity) |
| app | `GET /orders?customerId=` | order-service | none | Cell-local history |
| app | `GET /inventory/{sku}` | inventory-service | none | Cache-aside read model (I6) |
| app | `/admin/**` | — | — | **404**, not 401/403 — the public host never admits the path exists |
| admin | `POST /admin/leases/grant` | inventory-service | Access JWT + `ROLE_LEASE_ALLOCATOR` | §4 bounds apply |
| admin | `GET /admin/leases/report` | inventory-service | Access JWT + `ROLE_LEASE_ALLOCATOR` | I5 — allocator reads `sold_qty` |
| admin | anything else | — | — | 404 |
| internal | `POST /reservations` | inventory-service | NetworkPolicy (order-service pods only) | Never routed by the gateway |
| internal | `/actuator/**` | each service, **management port 9080** | NetworkPolicy (Prometheus agent, kubelet probes) | Not in any Service the Ingress points at |

**Lease renewal direction.** The cell never initiates a call to the control plane (no outbound cross-cloud dependency on the request path or in the background). The allocator drives every cycle: every 5 minutes it reads `GET /admin/leases/report` from each cell and re-grants with `POST /admin/leases/grant` carrying `epoch + 1` and a fresh `expires_at`. If the allocator can't reach a cell, that cell's leases simply expire and it stops selling — the fail-safe direction.

## 3. Admin authentication

### 3.1 Cloudflare side (Terraform lives in cloudbridge-cloudflare-traffic)

- One Cloudflare Access **self-hosted application** per cell admin hostname, path `/admin/*`.
- One **Service Auth** policy allowing only the allocator's **service token**. No human identity providers on this app.
- The allocator sends `CF-Access-Client-Id` / `CF-Access-Client-Secret` (secret read from GCP Secret Manager at startup, never logged). Cloudflare verifies them at the edge and forwards the request with a signed JWT in the `Cf-Access-Jwt-Assertion` header.

### 3.2 Origin side — validate the JWT, always

Cloudflare's own guidance is to validate the Access JWT at the origin; it's the only thing that proves the request passed *your* Access policy rather than someone else's Cloudflare zone.

| Check | Value |
|---|---|
| Token source | `Cf-Access-Jwt-Assertion` request header (never the `CF_Authorization` cookie — no browsers on this API) |
| Signature | RS256 against JWKS `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` (keys rotate; Nimbus caches and refetches by `kid`) |
| Issuer | `https://<team>.cloudflareaccess.com` |
| Audience | contains the application's **AUD tag** (one per cell admin app) |
| Time | `exp` / `nbf` with 30 s clock skew |
| Identity | claim `common_name` = the service token's Client ID; must be in `cloudbridge.admin.allowed-service-tokens` → authority `ROLE_LEASE_ALLOCATOR` |

Verify the claim name (`common_name`) against Cloudflare's Access JWT docs on build day; it's the one field that ties the token to a specific service token.

**Fail closed.** Missing `team-domain`, `audience` or an empty allowlist must stop the application from starting (`@Validated` properties), not silently disable the admin chain.

### 3.3 Where it is enforced

1. **Gateway** — admin `SecurityFilterChain` (host + path matcher) validates the JWT and requires the role; the public chain returns 404 for `/admin/**` and for every path on the admin host.
2. **inventory-service** — validates the **same** forwarded JWT with the same properties and requires the same role (defence in depth: a misrouted request or a compromised pod in `cb-app` still can't grant). Add `spring-boot-starter-security` and `spring-boot-starter-security-oauth2-resource-server` to inventory-service together with this config — adding the starters without a `SecurityFilterChain` locks every endpoint.
3. **NetworkPolicy** — inventory `:8082` accepts traffic only from gateway and order-service pods.

Optional hardening: Cloudflare **Authenticated Origin Pulls** (mTLS from Cloudflare to the origin). Interview line: *"An IP allowlist says the request came from Cloudflare. The Access JWT says it came through my policy. I check the second one."*

## 4. Grant semantics

Auth stops strangers. Bounds stop a buggy or compromised allocator from doing unbounded damage. All checks run in one transaction with the lease row locked.

| Rule | Check | Outcome / status | Why |
|---|---|---|---|
| Known SKU | row in `inventory.products` | `UNKNOWN_SKU` / 422 | No leases for products the cell doesn't sell |
| Positive epoch | `epoch ≥ 1` | `OUT_OF_BOUNDS` / 422 | |
| Fencing | `epoch > current_epoch` | `STALE` / 409 `stale-lease-epoch` | Zombie or delayed allocator can't overwrite a newer grant |
| Epoch jump cap | `epoch ≤ current_epoch + max-epoch-jump` (default 1000; `current_epoch = 0` when no lease yet) | `OUT_OF_BOUNDS` / 422 | One bad grant can't burn the epoch space and fence the real allocator forever |
| TTL cap | `now < expires_at ≤ now + max-lease-ttl` (default 20 min; allocator uses 15) | `OUT_OF_BOUNDS` / 422 | No perpetual leases that survive a partition |
| Quantity cap | `0 ≤ remainingQty ≤ max_cell_grant` (`products.max_cell_grant`, else `default-max-cell-grant`) | `OUT_OF_BOUNDS` / 422 | Bounds the damage of any single grant |
| Replay | same `(sku, epoch)` already `APPLIED` with the same quantity and expiry | `REPLAYED` / 200 `{replayed: true}` | Allocator retries after a timeout are safe |
| Epoch reuse | same `(sku, epoch)` already applied with a **different** grant | `EPOCH_REUSED` / 409 `stale-lease-epoch` | One epoch, one grant |
| Reported sold | `0 ≤ reportedSold ≤ current granted_qty` | `OUT_OF_BOUNDS` / 422 rule `reported-sold` | A cell can't have sold more than it was ever granted, so a larger figure didn't come from its report |
| Apply | I4 upsert (`granted_qty = GREATEST(sold_qty, reportedSold + remainingQty)`) | `APPLIED` / 200 `{epoch, grantedQty, replayed}` | Sales after the report come out of the new grant; `grantedQty` tells the allocator what the cell really holds |

Every attempt that passes auth — applied or rejected — is written to `inventory.lease_grant_log` with the caller's `common_name` and the JWT `jti`. Attempts rejected by auth never reach inventory; the gateway counts them in `cb_admin_auth_failures_total{reason}` (alert on any non-zero rate on prod).

## 5. API contract

### 5.1 Idempotency-Key

| Rule | Behaviour |
|---|---|
| Format | UUID (v4 or v7), generated by the client **per logical operation**, reused on every retry of that operation |
| Required on | `POST /orders` — gateway returns 400 `missing-idempotency-key` if absent or not a UUID. The gateway itself never retries POST (GETs only); the client retries with the same key |
| Same key, same body | Original status and body, plus `Idempotent-Replayed: true` |
| Same key, different body | 422 `idempotency-key-reused` |
| Key still `PENDING` | 409 `request-in-progress` + `Retry-After: 1` |
| Key `FAILED` | Client may retry with the same key and body (re-claim, O3) |
| Body identity | SHA-256 of the canonical JSON of the request record (fixed field order from the record) |
| Retention | 24 h (sweep O6); stuck `PENDING` > 2 min → `FAILED` (O7) |
| Scope | **Per cell.** Honest limitation: if the home cell dies mid-request and the retry lands in the other cell, a second order can be created there. It's detectable afterwards (same `reservation_id` in two cells) and is listed in the leaky-abstraction register — never claim exactly-once across clouds |

### 5.2 Errors — RFC 9457 ProblemDetail

Every error body is `application/problem+json`:

```json
{
  "type": "https://cloudbridge.example/problems/out-of-stock-in-cell",
  "title": "Out of stock in this cell",
  "status": 409,
  "detail": "SKU-42 has no sellable quantity under this cell's lease",
  "instance": "/orders",
  "cell": "cb-gcp-prod",
  "sku": "SKU-42",
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736"
}
```

| Status | `type` slug | When |
|---|---|---|
| 400 | `missing-idempotency-key` | `POST /orders` without a valid UUID key |
| 400 | `validation-failed` | Bean Validation failure; extension `errors: [{field, message}]` |
| 401 | `unauthenticated` | Admin host, missing/invalid Access JWT |
| 403 | `forbidden` | Admin host, valid JWT, service token not allowlisted |
| 404 | `not-found` | Unknown resource; any `/admin/**` on the public host |
| 409 | `out-of-stock-in-cell` | Lease exhausted or expired in this cell (extension `sku`) |
| 409 | `request-in-progress` | Idempotency key `PENDING` (+ `Retry-After: 1`) |
| 409 | `stale-lease-epoch` | Fenced or reused epoch |
| 413 | `payload-too-large` | Body over 16 KB |
| 422 | `idempotency-key-reused` | Same key, different body |
| 422 | `lease-grant-out-of-bounds` | §4 bounds (extension `rule`) |
| 429 | `rate-limited` | Rate limit exceeded (+ `Retry-After`) |
| 503 | `overloaded` | Load shedding (+ `Retry-After: 2`) |
| 503 | `dependency-unavailable` | Circuit open on a required dependency (+ `Retry-After`) |

`type` URIs are stable identifiers — clients switch on `type`, never on `detail` text.

### 5.3 Rate limiting (gateway)

- Client key: `CF-Connecting-IP`. Trustworthy **only** because the origin accepts nothing but Cloudflare (cloudflare-traffic); fall back to the socket address in local dev.
- Limits (fixed 60 s window): `GET` 120/min, `POST /orders` 30/min. `/healthz/cell` and `/admin/**` are excluded.
- Store: Valkey `rl:{client}:{route}:{window}` via `INCR` + `EXPIRE 60`, behind the `valkey` circuit breaker. **Fails open** to an in-memory per-pod window (conservative limits) — a cache outage must not become an API outage.
- Headers on every limited route: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` (seconds to window end). On 429 add `Retry-After`.

### 5.4 Load shedding

When in-flight requests exceed `cloudbridge.shedding.max-in-flight`, the gateway answers 503 `overloaded` with `Retry-After: 2` immediately. `/healthz/cell` and actuator are excluded — shedding is graceful degradation; the cell stays in the pool.

### 5.5 CORS

| Setting | Value |
|---|---|
| Allowed origins | `https://cp.<domain>` (control-plane dashboard); `http://localhost:3000` only in the `local` profile |
| Allowed methods | `GET`, `POST`, `OPTIONS` |
| Allowed headers | `Content-Type`, `Idempotency-Key` |
| Exposed headers | `X-CB-Cell`, `Idempotent-Replayed`, `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `Retry-After` |
| Credentials | `false` (the Cloudflare affinity cookie is same-site on `app.<domain>`) |
| Max age | 600 s |
| `/admin/**` | No CORS configuration at all — browsers never call it |

### 5.6 Input limits and response headers

- Body ≤ 16 KB (`server.tomcat.max-swallow-size` + a size check filter → 413); 1–50 items per order; `qty` 1–100; `pricePaise ≥ 0`; `customerId` required.
- `X-CB-Cell: <cell>` on every response (proves which cloud served you).
- `X-Content-Type-Options: nosniff`; `Cache-Control: no-store` on `/orders/**`. HSTS is set at Cloudflare.

---

## 6. Code

Spring Boot 4.1 / Spring Security 7 / Java 21. `AntPathRequestMatcher` was removed in Security 7 — use `PathPatternRequestMatcher`.

### 6.1 Properties

```yaml
# api-gateway application.yaml (security-relevant excerpt)
server:
  port: 8080
management:
  server:
    port: 9080                     # actuator never shares a port with the Ingress-facing listener

cloudbridge:
  cell: ${CB_CELL}
  admin:
    host: ${CB_ADMIN_HOST}                               # admin-aws.<domain>
    team-domain: ${CF_ACCESS_TEAM_DOMAIN}                # https://<team>.cloudflareaccess.com
    audience: ${CF_ACCESS_AUD}                           # AUD tag of this cell's admin Access app
    allowed-service-tokens: ${CF_ACCESS_ALLOWED_CLIENT_IDS}   # comma-separated Client IDs
    clock-skew: 30s
  cors:
    allowed-origins: ${CB_CORS_ORIGINS:https://cp.example.invalid}
  rate-limit:
    get-per-minute: 120
    order-post-per-minute: 30
  shedding:
    max-in-flight: 200

spring:
  cloud:
    gateway:
      server:
        webmvc:
          routes:
            - id: admin-leases
              uri: ${INVENTORY_URL}
              predicates:
                - Host=${CB_ADMIN_HOST}
                - Path=/admin/leases/**
              # Cf-Access-Jwt-Assertion is forwarded unchanged; inventory re-validates it
```

```java
// dev/cloudbridge/gateway/security/AdminProperties.java
package dev.cloudbridge.gateway.security;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;
import java.net.URI;
import java.time.Duration;
import java.util.Set;

/** Fail closed: a missing value stops start-up instead of silently disabling admin auth. */
@Validated
@ConfigurationProperties("cloudbridge.admin")
public record AdminProperties(
        @NotBlank String host,
        @NotNull URI teamDomain,
        @NotBlank String audience,
        @NotEmpty Set<String> allowedServiceTokens,
        @NotNull Duration clockSkew) {

    public String jwksUri() { return teamDomain + "/cdn-cgi/access/certs"; }
    public String issuer()  { return teamDomain.toString(); }
}
```
Register with `@ConfigurationPropertiesScan` on the application class.

### 6.2 Access JWT decoding and authorities

```java
// dev/cloudbridge/gateway/security/CfAccessJwtConfig.java
package dev.cloudbridge.gateway.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.web.BearerTokenResolver;
import java.util.Collection;
import java.util.List;

@Configuration(proxyBeanMethods = false)
public class CfAccessJwtConfig {

    public static final String ACCESS_HEADER = "Cf-Access-Jwt-Assertion";
    public static final String ROLE_LEASE_ALLOCATOR = "ROLE_LEASE_ALLOCATOR";

    /** Cloudflare puts the Access JWT in its own header, not in Authorization: Bearer. */
    @Bean
    BearerTokenResolver cfAccessTokenResolver() {
        return request -> request.getHeader(ACCESS_HEADER);
    }

    @Bean
    JwtDecoder cfAccessJwtDecoder(AdminProperties props) {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(props.jwksUri()).build();
        decoder.setJwtValidator(validator(props));
        return decoder;
    }

    /** Package-visible so tests can exercise the exact production validator. */
    static OAuth2TokenValidator<Jwt> validator(AdminProperties props) {
        return new DelegatingOAuth2TokenValidator<>(
            new JwtTimestampValidator(props.clockSkew()),
            new JwtIssuerValidator(props.issuer()),
            new JwtClaimValidator<List<String>>(JwtClaimNames.AUD,
                aud -> aud != null && aud.contains(props.audience())));
    }

    /** Service token Client ID (claim common_name) → ROLE_LEASE_ALLOCATOR if allowlisted, else no authority. */
    static Converter<Jwt, Collection<GrantedAuthority>> serviceTokenAuthorities(AdminProperties props) {
        return jwt -> {
            String clientId = jwt.getClaimAsString("common_name");
            return clientId != null && props.allowedServiceTokens().contains(clientId)
                ? List.of(new SimpleGrantedAuthority(ROLE_LEASE_ALLOCATOR))
                : List.of();
        };
    }

    @Bean
    JwtAuthenticationConverter cfAccessAuthenticationConverter(AdminProperties props) {
        var converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(serviceTokenAuthorities(props));
        converter.setPrincipalClaimName("common_name");
        return converter;
    }
}
```

### 6.3 Two filter chains: admin host vs everything else

```java
// dev/cloudbridge/gateway/security/SecurityConfig.java
package dev.cloudbridge.gateway.security;

import jakarta.servlet.http.HttpServletResponse;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.web.BearerTokenResolver;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;
import org.springframework.security.web.util.matcher.AndRequestMatcher;
import org.springframework.security.web.util.matcher.RequestMatcher;

@Configuration(proxyBeanMethods = false)
class SecurityConfig {

    private static final PathPatternRequestMatcher.Builder PATHS = PathPatternRequestMatcher.withDefaults();

    static RequestMatcher hostIs(String host) {
        return request -> host.equalsIgnoreCase(request.getServerName());
    }

    /** Admin host + /admin/** only. Unauthenticated → 401, wrong service token → 403. */
    @Bean
    @Order(1)
    SecurityFilterChain adminChain(HttpSecurity http, AdminProperties props, BearerTokenResolver resolver,
                                   JwtDecoder decoder, JwtAuthenticationConverter converter) throws Exception {
        http.securityMatcher(new AndRequestMatcher(hostIs(props.host()), PATHS.matcher("/admin/**")))
            .authorizeHttpRequests(a -> a
                .requestMatchers(PATHS.matcher(HttpMethod.POST, "/admin/leases/grant"),
                                 PATHS.matcher(HttpMethod.GET, "/admin/leases/report"))
                    .hasAuthority(CfAccessJwtConfig.ROLE_LEASE_ALLOCATOR)
                .anyRequest().denyAll())
            .oauth2ResourceServer(o -> o
                .bearerTokenResolver(resolver)
                .jwt(j -> j.decoder(decoder).jwtAuthenticationConverter(converter)))
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            // Enabled, with only the listed routes exempt. The token repository must stay stateless: Spring's
            // default opens an HTTP session for any anonymous POST to an unlisted route, which is a free way
            // to fill a 2 GiB VM's memory. StatelessCsrfTokenRepository saves nothing and loads nothing.
            .csrf(c -> c.csrfTokenRepository(new StatelessCsrfTokenRepository()).ignoringRequestMatchers(/* the listed routes */))
            .cors(c -> c.disable());         // no browser ever calls the admin API
        return http.build();
    }

    /** Everything else. The admin host and /admin/** on the public host are invisible (404). */
    @Bean
    @Order(2)
    SecurityFilterChain publicChain(HttpSecurity http, AdminProperties props) throws Exception {
        http.authorizeHttpRequests(a -> a
                .requestMatchers(hostIs(props.host())).denyAll()
                .requestMatchers(PATHS.matcher("/admin/**")).denyAll()
                .requestMatchers(PATHS.matcher(HttpMethod.GET, "/healthz/cell")).permitAll()
                .requestMatchers(PATHS.matcher("/actuator/health/**"), PATHS.matcher("/actuator/prometheus"),
                                 PATHS.matcher("/actuator/info")).permitAll()   // management port 9080, NetworkPolicy-guarded
                .requestMatchers(PATHS.matcher(HttpMethod.POST, "/orders"),
                                 PATHS.matcher(HttpMethod.GET, "/orders"),
                                 PATHS.matcher(HttpMethod.GET, "/orders/*"),
                                 PATHS.matcher(HttpMethod.GET, "/inventory/*")).permitAll()
                .requestMatchers(PATHS.matcher(HttpMethod.OPTIONS, "/**")).permitAll()
                .anyRequest().denyAll())
            .exceptionHandling(e -> e
                .authenticationEntryPoint((req, res, ex) -> res.sendError(HttpServletResponse.SC_NOT_FOUND))
                .accessDeniedHandler((req, res, ex) -> res.sendError(HttpServletResponse.SC_NOT_FOUND)))
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .csrf(c -> c.csrfTokenRepository(new StatelessCsrfTokenRepository()).ignoringRequestMatchers(/* the listed routes */))
            .cors(Customizer.withDefaults())                       // uses the CorsConfigurationSource bean
            .headers(h -> h.contentTypeOptions(Customizer.withDefaults()));
        return http.build();
    }
}
```

**inventory-service** uses the same `AdminProperties` + `CfAccessJwtConfig` (copy the two classes into `dev.cloudbridge.inventory.security`) with a simpler chain: `securityMatcher("/admin/**")` → same JWT + role; a second chain permits `/reservations`, `/inventory/*` and actuator (they are NetworkPolicy-protected and never routed publicly) and denies everything else. No host matcher there — the gateway already enforced the host.

### 6.4 Problem catalog and advice

```java
// dev/cloudbridge/common/Problems.java  (one copy per service; identical file)
package dev.cloudbridge.common;

import org.slf4j.MDC;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ProblemDetail;
import java.net.URI;

public enum Problems {
    MISSING_IDEMPOTENCY_KEY(400, "missing-idempotency-key", "Idempotency-Key header required"),
    VALIDATION_FAILED(400, "validation-failed", "Request validation failed"),
    NOT_FOUND(404, "not-found", "Not found"),
    OUT_OF_STOCK_IN_CELL(409, "out-of-stock-in-cell", "Out of stock in this cell"),
    REQUEST_IN_PROGRESS(409, "request-in-progress", "Request with this key is in progress"),
    STALE_LEASE_EPOCH(409, "stale-lease-epoch", "Lease epoch is stale or already used"),
    PAYLOAD_TOO_LARGE(413, "payload-too-large", "Payload too large"),
    IDEMPOTENCY_KEY_REUSED(422, "idempotency-key-reused", "Idempotency-Key reused with a different body"),
    LEASE_GRANT_OUT_OF_BOUNDS(422, "lease-grant-out-of-bounds", "Lease grant outside allowed bounds"),
    RATE_LIMITED(429, "rate-limited", "Too many requests"),
    OVERLOADED(503, "overloaded", "Cell is shedding load"),
    DEPENDENCY_UNAVAILABLE(503, "dependency-unavailable", "A required dependency is unavailable");

    private static final String BASE = System.getenv().getOrDefault("CB_PROBLEM_BASE", "https://cloudbridge.example/problems/");
    private static final String CELL = System.getenv().getOrDefault("CB_CELL", "unknown");

    public final int status;
    public final String slug;
    public final String title;

    Problems(int status, String slug, String title) { this.status = status; this.slug = slug; this.title = title; }

    public ProblemDetail detail(String detail) {
        ProblemDetail pd = ProblemDetail.forStatusAndDetail(HttpStatusCode.valueOf(status), detail);
        pd.setType(URI.create(BASE + slug));
        pd.setTitle(title);
        pd.setProperty("cell", CELL);
        String traceId = MDC.get("traceId");
        if (traceId != null) pd.setProperty("traceId", traceId);
        return pd;
    }
}
```

Controllers return `ResponseEntity.status(p.status).contentType(MediaType.APPLICATION_PROBLEM_JSON).body(p.detail(...))`. A `@RestControllerAdvice` extending `ResponseEntityExceptionHandler` maps `MethodArgumentNotValidException` → `VALIDATION_FAILED` with an `errors` extension, and `CallNotPermittedException` (open breaker) → `DEPENDENCY_UNAVAILABLE` + `Retry-After`. Set `spring.mvc.problemdetails.enabled: true` so framework errors use the same shape.

### 6.5 Gateway filters: Idempotency-Key guard, rate limit, shedding

```java
// dev/cloudbridge/gateway/web/IdempotencyKeyGuard.java
package dev.cloudbridge.gateway.web;

import dev.cloudbridge.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;
import java.util.UUID;

/** POST /orders without a UUID Idempotency-Key never reaches order-service, so the Retry filter can't duplicate it. */
@Component
@Order(10)
class IdempotencyKeyGuard extends OncePerRequestFilter {
    @Override
    protected boolean shouldNotFilter(HttpServletRequest req) {
        return !("POST".equals(req.getMethod()) && "/orders".equals(req.getRequestURI()));
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        String key = req.getHeader("Idempotency-Key");
        try {
            UUID.fromString(key == null ? "" : key);
        } catch (IllegalArgumentException e) {
            ProblemWriter.write(res, Problems.MISSING_IDEMPOTENCY_KEY.detail("send a UUID Idempotency-Key per logical order"));
            return;
        }
        chain.doFilter(req, res);
    }
}
```

```java
// dev/cloudbridge/gateway/web/RateLimitFilter.java
package dev.cloudbridge.gateway.web;

import dev.cloudbridge.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.client.circuitbreaker.CircuitBreaker;
import org.springframework.cloud.client.circuitbreaker.CircuitBreakerFactory;
import org.springframework.core.annotation.Order;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

@Component
@Order(20)
class RateLimitFilter extends OncePerRequestFilter {
    private static final long WINDOW_S = 60;
    private final StringRedisTemplate valkey;
    private final CircuitBreaker breaker;
    private final int getLimit;
    private final int postLimit;
    // Fail-open fallback: per-pod counters for the current window only.
    private final ConcurrentHashMap<String, AtomicLong> local = new ConcurrentHashMap<>();
    private volatile long localWindow = -1;

    RateLimitFilter(StringRedisTemplate valkey, CircuitBreakerFactory<?, ?> breakers,
                    @Value("${cloudbridge.rate-limit.get-per-minute}") int getLimit,
                    @Value("${cloudbridge.rate-limit.order-post-per-minute}") int postLimit) {
        this.valkey = valkey;
        this.breaker = breakers.create("valkey");
        this.getLimit = getLimit;
        this.postLimit = postLimit;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest req) {
        String uri = req.getRequestURI();
        return uri.startsWith("/healthz/") || uri.startsWith("/admin/") || uri.startsWith("/actuator/")
            || "OPTIONS".equals(req.getMethod());
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        boolean post = "POST".equals(req.getMethod());
        int limit = post ? postLimit : getLimit;
        String client = clientKey(req);
        long now = Instant.now().getEpochSecond();
        long window = now / WINDOW_S;
        String key = "rl:" + client + ":" + (post ? "w" : "r") + ":" + window;

        long count = breaker.run(() -> {
            Long n = valkey.opsForValue().increment(key);
            if (n != null && n == 1) valkey.expire(key, Duration.ofSeconds(WINDOW_S));
            return n == null ? 0L : n;
        }, err -> localIncrement(key, window));

        long reset = WINDOW_S - (now % WINDOW_S);
        res.setHeader("RateLimit-Limit", String.valueOf(limit));
        res.setHeader("RateLimit-Remaining", String.valueOf(Math.max(0, limit - count)));
        res.setHeader("RateLimit-Reset", String.valueOf(reset));
        if (count > limit) {
            res.setHeader("Retry-After", String.valueOf(reset));
            ProblemWriter.write(res, Problems.RATE_LIMITED.detail("limit " + limit + " per minute"));
            return;
        }
        chain.doFilter(req, res);
    }

    /** Trust CF-Connecting-IP only because the origin accepts nothing but Cloudflare. */
    private static String clientKey(HttpServletRequest req) {
        String ip = req.getHeader("CF-Connecting-IP");
        return ip != null && !ip.isBlank() ? ip : req.getRemoteAddr();
    }

    private long localIncrement(String key, long window) {
        if (window != localWindow) {
            local.clear();
            localWindow = window;
        }
        return local.computeIfAbsent(key, k -> new AtomicLong()).incrementAndGet();
    }
}
```

```java
// dev/cloudbridge/gateway/web/LoadSheddingFilter.java
package dev.cloudbridge.gateway.web;

import dev.cloudbridge.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;
import java.util.concurrent.Semaphore;

@Component
@Order(5)   // before rate limiting: shedding is cheaper than a Valkey round trip
class LoadSheddingFilter extends OncePerRequestFilter {
    private final Semaphore inFlight;

    LoadSheddingFilter(@Value("${cloudbridge.shedding.max-in-flight}") int maxInFlight) {
        this.inFlight = new Semaphore(maxInFlight);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest req) {
        String uri = req.getRequestURI();
        return uri.startsWith("/healthz/") || uri.startsWith("/actuator/");   // the cell stays in the pool
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        if (!inFlight.tryAcquire()) {
            res.setHeader("Retry-After", "2");
            ProblemWriter.write(res, Problems.OVERLOADED.detail("in-flight limit reached"));
            return;
        }
        try {
            chain.doFilter(req, res);
        } finally {
            inFlight.release();
        }
    }
}
```

```java
// dev/cloudbridge/gateway/web/ProblemWriter.java
package dev.cloudbridge.gateway.web;

import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import tools.jackson.databind.json.JsonMapper;
import java.io.IOException;

final class ProblemWriter {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private ProblemWriter() {}

    static void write(HttpServletResponse res, ProblemDetail pd) throws IOException {
        res.setStatus(pd.getStatus());
        res.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
        JSON.writeValue(res.getOutputStream(), pd);
    }
}
```

### 6.6 CORS

```java
// dev/cloudbridge/gateway/web/CorsConfig.java
package dev.cloudbridge.gateway.web;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;
import java.util.List;

@Configuration(proxyBeanMethods = false)
class CorsConfig {
    @Bean
    CorsConfigurationSource corsConfigurationSource(@Value("${cloudbridge.cors.allowed-origins}") List<String> origins) {
        var cfg = new CorsConfiguration();
        cfg.setAllowedOrigins(origins);                       // exact origins, never "*"
        cfg.setAllowedMethods(List.of("GET", "POST", "OPTIONS"));
        cfg.setAllowedHeaders(List.of("Content-Type", "Idempotency-Key"));
        cfg.setExposedHeaders(List.of("X-CB-Cell", "Idempotent-Replayed", "RateLimit-Limit",
                                      "RateLimit-Remaining", "RateLimit-Reset", "Retry-After"));
        cfg.setAllowCredentials(false);
        cfg.setMaxAge(600L);
        var source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/orders/**", cfg);
        source.registerCorsConfiguration("/orders", cfg);
        source.registerCorsConfiguration("/inventory/**", cfg);
        return source;                                        // nothing registered for /admin/**
    }
}
```

### 6.7 Hardened lease API (inventory-service)

Expand-only migration, safe with the previous app version:

```sql
-- services/inventory-service/src/main/resources/db/migration/V2__lease_admin_hardening.sql
ALTER TABLE inventory.products
    ADD COLUMN IF NOT EXISTS max_cell_grant int CHECK (max_cell_grant >= 0);   -- NULL → default-max-cell-grant

CREATE TABLE IF NOT EXISTS inventory.lease_grant_log (
    id           uuid        PRIMARY KEY DEFAULT uuidv7(),
    sku          text        NOT NULL,
    epoch        bigint      NOT NULL,
    granted_qty  int         NOT NULL,                 -- remaining quantity as sent by the allocator
    reported_sold int        NOT NULL,                 -- the sold_qty that remaining was computed against
    expires_at   timestamptz NOT NULL,
    actor        text        NOT NULL,                 -- Access JWT common_name (service token Client ID)
    jti          text,
    outcome      text        NOT NULL CHECK (outcome IN
                   ('APPLIED', 'REPLAYED', 'STALE', 'EPOCH_REUSED', 'OUT_OF_BOUNDS', 'UNKNOWN_SKU')),
    rule         text,                                 -- which bound failed, for OUT_OF_BOUNDS
    received_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lease_grant_log_applied ON inventory.lease_grant_log (sku, epoch) WHERE outcome = 'APPLIED';
CREATE INDEX IF NOT EXISTS lease_grant_log_received ON inventory.lease_grant_log (received_at);   -- 30-day sweep
```

The code is in the repo and is the reference: `services/inventory-service/src/main/java/dev/cloudbridge/inventory/lease/{LeaseGrantService,LeaseController}.java`. Provide a `Clock` bean (`Clock.systemUTC()`). What matters when changing it:

- `POST /admin/leases/grant` takes `{sku, remainingQty, reportedSold, epoch, expiresAt}` and answers `{epoch, grantedQty, replayed}`. `GET /admin/leases/report` answers `[{sku, grantedQty, soldQty, leaseEpoch, expiresAt}]`.
- `reportedSold` and the returned `grantedQty` are what make "never oversell" true across cells (Week 4: a randomized allocator test oversold without them). With I4 as first written (`remaining + current sold_qty`), units sold between report and grant were added on top of the grant. And a cell that sold past a shrunken total keeps those sales, so the allocator must clip the next cell against the answer, not against what it asked for.
- An empty `RETURNING` (a concurrent first grant won the insert) is `STALE`, not an exception.

---

## 7. Tests

Gateway — unit-test the exact production validator and authorities converter, then MockMvc for routing and roles (`spring-security-test`'s `jwt()` bypasses the decoder, so audience/issuer are covered by the validator test):

```java
// api-gateway/src/test/java/dev/cloudbridge/gateway/security/CfAccessJwtConfigTest.java
package dev.cloudbridge.gateway.security;

import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;
import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class CfAccessJwtConfigTest {
    static final AdminProperties PROPS = new AdminProperties("admin-aws.example.test",
        URI.create("https://team.cloudflareaccess.com"), "aud-aws", Set.of("allocator-client-id"), Duration.ofSeconds(30));

    static Jwt jwt(String aud, String issuer, String commonName) {
        return Jwt.withTokenValue("t").header("alg", "RS256")
            .issuer(issuer).audience(List.of(aud)).claim("common_name", commonName)
            .issuedAt(Instant.now().minusSeconds(5)).expiresAt(Instant.now().plusSeconds(300)).build();
    }

    @Test void acceptsCorrectIssuerAndAudience() {
        assertThat(CfAccessJwtConfig.validator(PROPS)
            .validate(jwt("aud-aws", "https://team.cloudflareaccess.com", "allocator-client-id")).hasErrors()).isFalse();
    }

    @Test void rejectsOtherCellsAudience() {
        assertThat(CfAccessJwtConfig.validator(PROPS)
            .validate(jwt("aud-gcp", "https://team.cloudflareaccess.com", "allocator-client-id")).hasErrors()).isTrue();
    }

    @Test void rejectsForeignTeam() {
        assertThat(CfAccessJwtConfig.validator(PROPS)
            .validate(jwt("aud-aws", "https://attacker.cloudflareaccess.com", "allocator-client-id")).hasErrors()).isTrue();
    }

    @Test void onlyAllowlistedServiceTokenGetsTheRole() {
        var conv = CfAccessJwtConfig.serviceTokenAuthorities(PROPS);
        assertThat(conv.convert(jwt("aud-aws", "https://team.cloudflareaccess.com", "allocator-client-id")))
            .extracting(Object::toString).containsExactly(CfAccessJwtConfig.ROLE_LEASE_ALLOCATOR);
        assertThat(conv.convert(jwt("aud-aws", "https://team.cloudflareaccess.com", "someone-else"))).isEmpty();
    }
}
```

MockMvc scenarios (`@SpringBootTest` + `@AutoConfigureMockMvc`; in Boot 4 the annotation lives in the `spring-boot-webmvc-test` module — `org.springframework.boot.webmvc.test.autoconfigure`; use absolute URLs such as `post("https://admin-aws.example.test/admin/leases/grant")` to set the host):

| Request | Expected |
|---|---|
| Admin host, no `Cf-Access-Jwt-Assertion` | 401 |
| Admin host, `jwt()` with `common_name` not allowlisted (`.authorities(serviceTokenAuthorities(props))`) | 403 |
| Admin host, allowlisted `jwt()` | not 401/403/404 (passes security; upstream may be absent in the test) |
| Public host, allowlisted `jwt()` on `/admin/leases/grant` | 404 |
| Admin host, `GET /orders` | 404 |
| `POST /orders` without `Idempotency-Key` | 400 `missing-idempotency-key` |
| CORS preflight from `https://evil.example` | 403, no `Access-Control-Allow-Origin` |
| 31st `POST /orders` in a minute from one `CF-Connecting-IP` | 429 with `Retry-After` and `RateLimit-Remaining: 0` |

inventory-service — `LeaseGrantServiceIT` (Testcontainers `postgres:18.4-alpine`, fixed `Clock`):

| Scenario | Expected |
|---|---|
| Grant epoch 5, then epoch 4 | `STALE`, lease stays epoch 5 |
| First grant with epoch 1,000,001 (no lease yet) | `OUT_OF_BOUNDS` rule `epoch-jump` |
| `expiresAt = now + 2 h` | `OUT_OF_BOUNDS` rule `ttl` |
| `remainingQty` above `max_cell_grant` | `OUT_OF_BOUNDS` rule `quantity` |
| Same grant twice (same epoch, qty, expiry) | `APPLIED` then `REPLAYED` |
| Same epoch, different qty | `EPOCH_REUSED` |
| Every case above | exactly one `lease_grant_log` row with the caller's `actor` |

Interview soundbite: *"The lease API is the one endpoint that can break 'never oversell', so it has three locks: Cloudflare Access proves the caller is my allocator, the origin re-validates the JWT because an IP allowlist only proves 'from Cloudflare', and even a valid grant is bounded — epoch jump, TTL and quantity caps — and audited."*
