# Cell Services — Starter Code (Spring Boot 4.1, Java 21, Maven)

Package root `dev.cloudbridge`. Code uses Spring Framework 7 APIs (`JdbcClient`, `RestClient`, built-in `@ConcurrencyLimit` / `@Retryable` with `@EnableResilientMethods`), Jackson 3 (`tools.jackson.*`, Boot 4's default), Testcontainers 2.x and Resilience4j 2.4.0 (`resilience4j-spring-boot4`) for circuit breakers. Security for the admin lease API and the public API contract are in `security-and-api.md`.

## Contents
1. `pom.xml` (order-service; the others differ only in dependencies)
2. `application.yml`
3. order-service: `IdempotentOrderService`, `OrderController`, `OutboxRelay`, `InventoryClient`
4. inventory-service: `ReservationService`, `LeaseController`, `ReservationReaper`
5. api-gateway: `CellHealthController`, cell header filter, load shedding
6. Tests (Testcontainers): idempotency, concurrent reservations, fencing, health

---

## 1. pom.xml

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.1.1</version> <!-- floating 4.1.x patch; bump with Dependabot -->
  </parent>
  <groupId>dev.cloudbridge</groupId>
  <artifactId>order-service</artifactId>
  <version>0.1.0</version>
  <properties>
    <java.version>21</java.version>
  </properties>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-webmvc</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-jdbc</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-data-redis</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-actuator</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-flyway</artifactId></dependency>
    <dependency><groupId>org.flywaydb</groupId><artifactId>flyway-database-postgresql</artifactId></dependency>
    <dependency><groupId>org.postgresql</groupId><artifactId>postgresql</artifactId><scope>runtime</scope></dependency>
    <dependency><groupId>io.micrometer</groupId><artifactId>micrometer-registry-prometheus</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-validation</artifactId></dependency>
    <!-- Resilience4j's Boot 4 integration; not in the Boot BOM yet, so the version is pinned here -->
    <dependency><groupId>io.github.resilience4j</groupId><artifactId>resilience4j-spring-boot4</artifactId><version>2.4.0</version></dependency>
    <!-- Boot 4's new name for spring-boot-starter-aop; the @CircuitBreaker aspect needs it -->
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-aspectj</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-test</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-testcontainers</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.testcontainers</groupId><artifactId>testcontainers-junit-jupiter</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.testcontainers</groupId><artifactId>testcontainers-postgresql</artifactId><scope>test</scope></dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId></plugin>
    </plugins>
  </build>
</project>
```
Resilience4j's Spring Boot integration artifact tracks Boot generations: `resilience4j-spring-boot4` **2.4.0** is the Boot 4 one (`resilience4j-spring-boot3` is Boot 3 only, and there is no Resilience4j 3.x). The api-gateway does **not** add it — it gets Resilience4j through `spring-cloud-starter-circuitbreaker-resilience4j`, managed by the Spring Cloud 2025.1.3 BOM. Testcontainers 2.x artifacts are prefixed `testcontainers-` and managed by the Boot 4.1 BOM.

## 2. application.yml

```yaml
spring:
  application:
    name: order-service
  threads:
    virtual:
      enabled: true
  datasource:
    url: ${SPRING_DATASOURCE_URL}
    hikari:
      maximum-pool-size: ${DB_POOL_SIZE:10}
      connection-timeout: 2000
      data-source-properties:
        socketTimeout: 3
  flyway:
    schemas: orders
    default-schema: orders
  data:
    redis:
      url: ${VALKEY_URL}
      timeout: 300ms

server:
  port: 8081
  shutdown: graceful

management:
  endpoints:
    web:
      exposure:
        include: health,prometheus,info
  endpoint:
    health:
      probes:
        enabled: true
      group:
        readiness:
          include: readinessState,db          # NOT redis — cache failure must not unready the pod
  metrics:
    tags:
      cb_cell: ${CB_CELL:unknown}
      service: ${spring.application.name}
    distribution:
      percentiles-histogram:
        http.server.requests: true

cloudbridge:
  cell: ${CB_CELL}
  inventory-url: ${INVENTORY_URL:http://inventory-service:8082}

resilience4j:
  circuitbreaker:
    instances:
      inventory:
        sliding-window-size: 20
        failure-rate-threshold: 50
        wait-duration-in-open-state: 30s
        permitted-number-of-calls-in-half-open-state: 5
      valkey:
        sliding-window-size: 20
        failure-rate-threshold: 50
        wait-duration-in-open-state: 15s
```

## 3. order-service

```java
// dev/cloudbridge/order/OrderModels.java
package dev.cloudbridge.order;

import java.util.List;
import java.util.UUID;

public final class OrderModels {
    private OrderModels() {}
    public record Item(String sku, int qty, long pricePaise) {}
    public record CreateOrder(UUID customerId, List<Item> items) {
        public long totalPaise() { return items.stream().mapToLong(i -> i.pricePaise() * i.qty()).sum(); }
    }
    public record OrderCreated(UUID orderId, String cell, long totalPaise) {}
    public sealed interface Outcome permits Created, Replayed, InProgress, Mismatch, OutOfStock {}
    public record Created(OrderCreated body) implements Outcome {}
    public record Replayed(int status, String body) implements Outcome {}
    public record InProgress() implements Outcome {}
    public record Mismatch() implements Outcome {}
    public record OutOfStock(String sku) implements Outcome {}
}
```

```java
// dev/cloudbridge/order/IdempotentOrderService.java
package dev.cloudbridge.order;

import tools.jackson.databind.json.JsonMapper;
import dev.cloudbridge.order.OrderModels.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.UUID;

@Service
public class IdempotentOrderService {
    private final JdbcClient jdbc;
    private final TransactionTemplate tx;
    private final InventoryClient inventory;
    private final JsonMapper json;
    private final String cell;

    public IdempotentOrderService(JdbcClient jdbc, TransactionTemplate tx, InventoryClient inventory,
                                  JsonMapper json, @Value("${cloudbridge.cell}") String cell) {
        this.jdbc = jdbc; this.tx = tx; this.inventory = inventory; this.json = json; this.cell = cell;
    }

    public Outcome create(UUID key, CreateOrder req) {
        String hash = sha256(toJson(req));

        // 1. Claim (own short transaction). Never hold a transaction across the HTTP call below.
        boolean claimed = jdbc.sql("""
                INSERT INTO orders.idempotency_keys (key, request_hash, status) VALUES (:k, :h, 'PENDING')
                ON CONFLICT (key) DO NOTHING RETURNING key""")
            .param("k", key).param("h", hash).query(UUID.class).optional().isPresent();

        if (!claimed) {
            var existing = jdbc.sql("SELECT status, request_hash, response_code, response_body::text AS body FROM orders.idempotency_keys WHERE key = :k")
                .param("k", key).query((rs, n) -> new Object[]{rs.getString(1), rs.getString(2), rs.getInt(3), rs.getString(4)})
                .single();
            if (!hash.equals(existing[1])) return new Mismatch();
            switch ((String) existing[0]) {
                case "COMPLETED": return new Replayed((Integer) existing[2], (String) existing[3]);
                case "PENDING":   return new InProgress();
                default: {        // FAILED → re-claim with the same body
                    boolean reclaimed = jdbc.sql("""
                        UPDATE orders.idempotency_keys SET status = 'PENDING', updated_at = now()
                         WHERE key = :k AND status = 'FAILED' AND request_hash = :h RETURNING key""")
                        .param("k", key).param("h", hash).query(UUID.class).optional().isPresent();
                    if (!reclaimed) return new InProgress();
                }
            }
        }

        // 2. Reserve (idempotent on the inventory side: reservation_id = key).
        for (Item item : req.items()) {
            if (!inventory.reserve(key, item.sku(), item.qty())) {
                markFailed(key);
                return new OutOfStock(item.sku());
            }
        }

        // 3. Commit order + items + outbox + key completion atomically.
        return tx.execute(status -> {
            UUID orderId = jdbc.sql("""
                    INSERT INTO orders.orders (cell, customer_id, status, total_paise, reservation_id)
                    VALUES (:cell, :cust, 'CONFIRMED', :total, :k) RETURNING id""")
                .param("cell", cell).param("cust", req.customerId()).param("total", req.totalPaise()).param("k", key)
                .query(UUID.class).single();
            for (Item i : req.items()) {
                jdbc.sql("INSERT INTO orders.order_items (order_id, sku, qty, price_paise) VALUES (:o, :s, :q, :p)")
                    .param("o", orderId).param("s", i.sku()).param("q", i.qty()).param("p", i.pricePaise()).update();
            }
            var body = new OrderCreated(orderId, cell, req.totalPaise());
            String bodyJson = toJson(body);
            jdbc.sql("""
                    INSERT INTO orders.outbox (aggregate, aggregate_id, event_type, payload)
                    VALUES ('order', :o, 'order.created', CAST(:p AS jsonb))""")
                .param("o", orderId)
                .param("p", toJson(java.util.Map.of("order_id", orderId, "reservation_id", key, "cell", cell)))
                .update();
            jdbc.sql("""
                    UPDATE orders.idempotency_keys
                       SET status = 'COMPLETED', order_id = :o, response_code = 201,
                           response_body = CAST(:b AS jsonb), updated_at = now()
                     WHERE key = :k""")
                .param("o", orderId).param("b", bodyJson).param("k", key).update();
            return new Created(body);
        });
    }

    private void markFailed(UUID key) {
        jdbc.sql("UPDATE orders.idempotency_keys SET status = 'FAILED', updated_at = now() WHERE key = :k")
            .param("k", key).update();
    }

    private String toJson(Object o) {
        return json.writeValueAsString(o);          // Jackson 3 throws unchecked JacksonException
    }

    private static String sha256(String s) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)));
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);       // SHA-256 is mandatory in every JRE
        }
    }
}
```
Spring Boot 4 uses Jackson 3: inject `tools.jackson.databind.json.JsonMapper` (auto-configured). Jackson 3 exceptions are unchecked, so no `throws Exception` leaks into the service API.

```java
// dev/cloudbridge/order/OrderController.java
package dev.cloudbridge.order;

import dev.cloudbridge.order.OrderModels.*;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;

@RestController
@RequestMapping("/orders")
class OrderController {
    private final IdempotentOrderService service;
    OrderController(IdempotentOrderService service) { this.service = service; }

    @PostMapping
    ResponseEntity<?> create(@RequestHeader("Idempotency-Key") UUID key, @RequestBody CreateOrder req) {
        return switch (service.create(key, req)) {
            case Created c     -> ResponseEntity.status(HttpStatus.CREATED).body(c.body());
            case Replayed r    -> ResponseEntity.status(r.status()).header("Idempotent-Replayed", "true")
                                    .contentType(MediaType.APPLICATION_JSON).body(r.body());
            case InProgress p  -> ResponseEntity.status(HttpStatus.CONFLICT).header(HttpHeaders.RETRY_AFTER, "1")
                                    .body(ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "request with this key is in progress"));
            case Mismatch m    -> ResponseEntity.unprocessableEntity()
                                    .body(ProblemDetail.forStatusAndDetail(HttpStatus.UNPROCESSABLE_ENTITY, "Idempotency-Key reused with a different body"));
            case OutOfStock o  -> ResponseEntity.status(HttpStatus.CONFLICT)
                                    .body(ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "out of stock in this cell: " + o.sku()));
        };
    }
}
```

```java
// dev/cloudbridge/order/InventoryClient.java
package dev.cloudbridge.order;

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import java.util.Map;
import java.util.UUID;

@Component
class InventoryClient {
    private final RestClient http;

    InventoryClient(@Value("${cloudbridge.inventory-url}") String baseUrl) {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout(800);
        rf.setReadTimeout(1500);
        this.http = RestClient.builder().baseUrl(baseUrl).requestFactory(rf).build();
    }

    /** Idempotent: calling twice with the same reservationId returns the same outcome. Safe to retry. */
    @CircuitBreaker(name = "inventory")
    boolean reserve(UUID reservationId, String sku, int qty) {
        try {
            http.post().uri("/reservations")
                .body(Map.of("reservationId", reservationId, "sku", sku, "qty", qty))
                .retrieve().toBodilessEntity();
            return true;
        } catch (HttpClientErrorException e) {
            if (e.getStatusCode() == HttpStatus.CONFLICT) return false;   // out of stock in this cell
            throw e;
        }
    }
}
```

```java
// dev/cloudbridge/order/OutboxRelay.java
package dev.cloudbridge.order;

import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import java.util.Map;
import java.util.UUID;

@Component
class OutboxRelay {
    private final JdbcClient jdbc;
    private final StringRedisTemplate valkey;
    OutboxRelay(JdbcClient jdbc, StringRedisTemplate valkey) { this.jdbc = jdbc; this.valkey = valkey; }

    record Row(UUID id, String type, String payload) {}

    @Scheduled(fixedDelay = 500)
    @Transactional
    void relay() {
        var rows = jdbc.sql("""
                SELECT id, event_type, payload::text FROM orders.outbox
                 WHERE published_at IS NULL ORDER BY created_at LIMIT 100 FOR UPDATE SKIP LOCKED""")
            .query((rs, n) -> new Row(rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3))).list();
        for (Row r : rows) {
            MapRecord<String, String, String> rec = StreamRecords.newRecord()
                .in("stream:cell-events")
                .ofMap(Map.of("id", r.id().toString(), "type", r.type(), "payload", r.payload()));
            valkey.opsForStream().add(rec);          // trim with XTRIM MAXLEN ~ 100000 in a separate schedule
            jdbc.sql("UPDATE orders.outbox SET published_at = now(), attempts = attempts + 1 WHERE id = :id")
                .param("id", r.id()).update();
        }
        // If Valkey is down, add() throws → transaction rolls back → rows stay unpublished → retried. At-least-once.
    }
}
```

## 4. inventory-service

```java
// dev/cloudbridge/inventory/ReservationService.java
package dev.cloudbridge.inventory;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.resilience.annotation.ConcurrencyLimit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

@Service
class ReservationService {
    private final JdbcClient jdbc;
    ReservationService(JdbcClient jdbc) { this.jdbc = jdbc; }

    enum Result { CREATED, REPLAYED, OUT_OF_STOCK }

    @Transactional
    @ConcurrencyLimit(32)                          // bulkhead on the DB-bound hot path
    Result reserve(UUID rid, String sku, int qty) {
        return jdbc.sql("""
                WITH existing AS (
                  SELECT reservation_id FROM inventory.reservations WHERE reservation_id = :rid
                ), dec AS (
                  UPDATE inventory.inventory_lease
                     SET sold_qty = sold_qty + :qty, updated_at = now()
                   WHERE sku = :sku AND NOT EXISTS (SELECT 1 FROM existing)
                     AND expires_at > now() AND sold_qty + :qty <= granted_qty
                  RETURNING sku
                ), ins AS (
                  INSERT INTO inventory.reservations (reservation_id, sku, qty, status)
                  SELECT :rid, :sku, :qty, 'HELD' FROM dec RETURNING reservation_id
                )
                SELECT 'CREATED' FROM ins
                UNION ALL
                SELECT 'REPLAYED' FROM existing""")
            .param("rid", rid).param("sku", sku).param("qty", qty)
            .query(String.class).optional()
            .map(Result::valueOf).orElse(Result.OUT_OF_STOCK);
    }
}
```
`@ConcurrencyLimit` comes from Spring Framework 7's built-in resilience support (enable with `@EnableResilientMethods` on a configuration class). A concurrent duplicate `rid` makes the second statement fail on the reservations primary key; the transaction rolls back (including its decrement) and the client's retry sees `REPLAYED`.

```java
// dev/cloudbridge/inventory/LeaseController.java
package dev.cloudbridge.inventory;

import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.*;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/admin/leases")        // SIMPLIFIED — no auth or bounds. Production version: security-and-api.md §6.7
class LeaseController {   // do not ship this one: anyone who can reach it can inflate stock or fence the allocator
    private final JdbcClient jdbc;
    LeaseController(JdbcClient jdbc) { this.jdbc = jdbc; }

    record Grant(String sku, int remainingQty, long epoch, OffsetDateTime expiresAt) {}

    @PostMapping("/grant")
    ResponseEntity<?> grant(@RequestBody Grant g) {
        var applied = jdbc.sql("""
                INSERT INTO inventory.inventory_lease (sku, granted_qty, sold_qty, lease_epoch, expires_at)
                VALUES (:sku, :granted, 0, :epoch, :exp)
                ON CONFLICT (sku) DO UPDATE
                   SET granted_qty = EXCLUDED.granted_qty + inventory.inventory_lease.sold_qty,
                       lease_epoch = EXCLUDED.lease_epoch, expires_at = EXCLUDED.expires_at, updated_at = now()
                 WHERE inventory.inventory_lease.lease_epoch < EXCLUDED.lease_epoch
                RETURNING lease_epoch""")
            .param("sku", g.sku()).param("granted", g.remainingQty()).param("epoch", g.epoch()).param("exp", g.expiresAt())
            .query(Long.class).optional();
        return applied.isPresent()
            ? ResponseEntity.ok(Map.of("epoch", applied.get()))
            : ResponseEntity.status(409).body(Map.of("error", "stale epoch — fenced"));
    }

    @GetMapping("/report")
    List<Map<String, Object>> report() {
        return jdbc.sql("SELECT sku, granted_qty, sold_qty, lease_epoch, expires_at FROM inventory.inventory_lease")
            .query().listOfRows();
    }
}
```

```java
// dev/cloudbridge/inventory/ReservationReaper.java
package dev.cloudbridge.inventory;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
class ReservationReaper {
    private final JdbcClient jdbc;
    ReservationReaper(JdbcClient jdbc) { this.jdbc = jdbc; }

    @Scheduled(fixedDelay = 60_000)
    @Transactional
    void releaseExpired() {
        jdbc.sql("""
            WITH expired AS (
              UPDATE inventory.reservations SET status = 'RELEASED', updated_at = now()
               WHERE status = 'HELD' AND created_at < now() - interval '15 minutes'
              RETURNING sku, qty
            ), per_sku AS (SELECT sku, sum(qty) AS qty FROM expired GROUP BY sku)
            UPDATE inventory.inventory_lease l SET sold_qty = l.sold_qty - p.qty, updated_at = now()
              FROM per_sku p WHERE l.sku = p.sku""").update();
    }
}
```

## 5. api-gateway

```java
// dev/cloudbridge/gateway/CellHealthController.java
package dev.cloudbridge.gateway;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/** "Can this cell take orders?" — what Cloudflare's monitor asks. Cache deliberately excluded. */
@RestController
class CellHealthController {
    private final RestClient orderSvc;
    private final JdbcClient db;          // read-only health user on the cell DB
    private final String cell;
    private final AtomicReference<Map.Entry<Instant, Boolean>> cache = new AtomicReference<>(Map.entry(Instant.EPOCH, false));

    CellHealthController(@Value("${cloudbridge.order-url}") String orderUrl, JdbcClient db, @Value("${cloudbridge.cell}") String cell) {
        var rf = new SimpleClientHttpRequestFactory();
        rf.setConnectTimeout(300);
        rf.setReadTimeout(500);
        this.orderSvc = RestClient.builder().baseUrl(orderUrl).requestFactory(rf).build();
        this.db = db;
        this.cell = cell;
    }

    @GetMapping("/healthz/cell")
    ResponseEntity<Map<String, Object>> health() {
        var cached = cache.get();
        boolean ok;
        if (cached.getKey().isAfter(Instant.now().minusSeconds(2))) {
            ok = cached.getValue();                     // probes from many regions must not hammer the DB
        } else {
            ok = check();
            cache.set(Map.entry(Instant.now(), ok));
        }
        var body = new LinkedHashMap<String, Object>();
        body.put("cell", cell);
        body.put("status", ok ? "UP" : "DOWN");
        return ResponseEntity.status(ok ? 200 : 503).body(body);
    }

    private boolean check() {
        try {
            orderSvc.get().uri("/actuator/health/readiness").retrieve().toBodilessEntity();
            Integer one = db.sql("SELECT 1").query(Integer.class).single();
            return one == 1;
        } catch (Exception e) {
            return false;
        }
    }
}
```

```yaml
# api-gateway application.yml (excerpt) — routes, timeouts, cell header, retries for idempotent calls only
spring:
  cloud:
    gateway:
      server:
        webmvc:                       # verify the property prefix for the Spring Cloud release train you pin
          routes:
            - id: orders
              uri: ${ORDER_URL}
              predicates:
                - Path=/orders/**
              filters:
                - AddResponseHeader=X-CB-Cell, ${CB_CELL}
                - name: CircuitBreaker
                  args:
                    name: orders
                    fallbackUri: forward:/fallback/unavailable
                - name: Retry
                  args:
                    retries: 2
                    methods: GET,POST           # POST /orders is safe only because it requires Idempotency-Key
                    statuses: BAD_GATEWAY,SERVICE_UNAVAILABLE
                    backoff:
                      firstBackoff: 50ms
                      maxBackoff: 400ms
                      factor: 2
            - id: inventory
              uri: ${INVENTORY_URL}
              predicates:
                - Path=/inventory/**
              filters:
                - AddResponseHeader=X-CB-Cell, ${CB_CELL}
                - name: Retry
                  args:
                    retries: 2
                    methods: GET
```
Reject `POST /orders` without `Idempotency-Key` at the gateway (400) so the retry filter can never duplicate an order. Load shedding: a servlet filter with a `Semaphore(maxInFlight)` that returns 503 + `Retry-After: 2` on `tryAcquire()` failure; exclude `/healthz/**` and `/actuator/**`.

## 6. Tests

Shared Testcontainers wiring (Testcontainers 2.x, same shape Initializr generates), with the images pinned:

```java
// src/test/java/dev/cloudbridge/order/TestcontainersConfiguration.java
package dev.cloudbridge.order;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

@TestConfiguration(proxyBeanMethods = false)
class TestcontainersConfiguration {
    @Bean
    @ServiceConnection
    PostgreSQLContainer postgresContainer() {
        return new PostgreSQLContainer(DockerImageName.parse("postgres:18.4-alpine"));     // PG18: uuidv7()
    }

    @Bean
    @ServiceConnection(name = "redis")                   // Valkey speaks the Redis protocol
    GenericContainer<?> valkeyContainer() {
        return new GenericContainer<>(DockerImageName.parse("valkey/valkey:9.0-alpine")).withExposedPorts(6379);
    }
}
```

```java
// order-service/src/test/java/dev/cloudbridge/order/IdempotencyIT.java
package dev.cloudbridge.order;

import dev.cloudbridge.order.OrderModels.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.when;

@Testcontainers
@SpringBootTest(properties = {"cloudbridge.cell=cb-test", "spring.data.redis.url=redis://localhost:6390"})
class IdempotencyIT {
    @Container @ServiceConnection
    static PostgreSQLContainer pg = new PostgreSQLContainer("postgres:18.4-alpine");   // Testcontainers 2.x: not generic

    @Autowired IdempotentOrderService service;
    @MockitoBean InventoryClient inventory;
    @MockitoBean OutboxRelay relay;                  // no Valkey needed for this test

    @Test
    void sameKeySameBodyCreatesOneOrder() {
        when(inventory.reserve(any(), anyString(), anyInt())).thenReturn(true);
        var key = UUID.randomUUID();
        var req = new CreateOrder(UUID.randomUUID(), List.of(new Item("SKU-1", 1, 49900)));
        assertThat(service.create(key, req)).isInstanceOf(Created.class);
        assertThat(service.create(key, req)).isInstanceOf(Replayed.class);
    }

    @Test
    void sameKeyDifferentBodyIsRejected() {
        when(inventory.reserve(any(), anyString(), anyInt())).thenReturn(true);
        var key = UUID.randomUUID();
        service.create(key, new CreateOrder(UUID.randomUUID(), List.of(new Item("SKU-1", 1, 49900))));
        assertThat(service.create(key, new CreateOrder(UUID.randomUUID(), List.of(new Item("SKU-1", 2, 49900)))))
            .isInstanceOf(Mismatch.class);
    }
}
```

```java
// inventory-service/src/test/java/dev/cloudbridge/inventory/EscrowIT.java  (core assertions)
@Test
void fiftyConcurrentReservationsAgainstLeaseOfTwentySellExactlyTwenty() throws Exception {
    jdbc.sql("INSERT INTO inventory.products VALUES ('SKU-1','Widget',49900)").update();
    jdbc.sql("INSERT INTO inventory.inventory_lease (sku, granted_qty, lease_epoch, expires_at) VALUES ('SKU-1', 20, 1, now() + interval '15 minutes')").update();
    try (var pool = java.util.concurrent.Executors.newVirtualThreadPerTaskExecutor()) {
        var futures = java.util.stream.IntStream.range(0, 50)
            .mapToObj(i -> pool.submit(() -> service.reserve(java.util.UUID.randomUUID(), "SKU-1", 1))).toList();
        long created = 0;
        for (var f : futures) if (f.get() == ReservationService.Result.CREATED) created++;
        assertThat(created).isEqualTo(20);
    }
    assertThat(jdbc.sql("SELECT sold_qty FROM inventory.inventory_lease WHERE sku='SKU-1'").query(Integer.class).single()).isEqualTo(20);
}

@Test
void staleEpochGrantIsFenced() {
    // grant epoch 5, then a delayed grant with epoch 4 arrives → 409 and epoch stays 5
}
```
