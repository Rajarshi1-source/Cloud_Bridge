# Cell Database — Schema & Queries (PostgreSQL 18)

One Postgres per cell (RDS / Cloud SQL / in-cluster on budget). Two schemas, one per owning service. Flyway runs per service against its own schema (`spring.flyway.schemas=orders` / `inventory`). Every migration must be compatible with the previous app version (expand → migrate → contract).

## orders schema (order-service)

```sql
-- services/order-service/src/main/resources/db/migration/V1__orders.sql
CREATE SCHEMA IF NOT EXISTS orders;
SET search_path TO orders;

CREATE TABLE orders (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),     -- PG18 built-in, time-ordered
    cell          text        NOT NULL,                         -- provenance: 'cb-gcp-prod'
    customer_id   uuid        NOT NULL,
    status        text        NOT NULL CHECK (status IN ('CONFIRMED', 'CANCELLED')),
    total_paise   bigint      NOT NULL CHECK (total_paise >= 0),
    currency      char(3)     NOT NULL DEFAULT 'INR',
    reservation_id uuid       NOT NULL UNIQUE,                  -- = Idempotency-Key
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_created ON orders (customer_id, created_at DESC);

CREATE TABLE order_items (
    order_id    uuid   NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    sku         text   NOT NULL,
    qty         int    NOT NULL CHECK (qty > 0),
    price_paise bigint NOT NULL CHECK (price_paise >= 0),
    PRIMARY KEY (order_id, sku)
);

CREATE TABLE idempotency_keys (
    key            uuid        PRIMARY KEY,
    request_hash   text        NOT NULL,                        -- sha256 of canonical request body
    status         text        NOT NULL CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED')),
    order_id       uuid        REFERENCES orders(id),
    response_code  int,
    response_body  jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idempotency_created ON idempotency_keys (created_at);

CREATE TABLE outbox (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    aggregate     text        NOT NULL,
    aggregate_id  uuid        NOT NULL,
    event_type    text        NOT NULL,
    payload       jsonb       NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    published_at  timestamptz,
    attempts      int         NOT NULL DEFAULT 0
);
CREATE INDEX outbox_unpublished ON outbox (created_at) WHERE published_at IS NULL;
```

### Queries (order-service)

```sql
-- O1. Claim an idempotency key. 1 row → we own it; 0 rows → look it up (O2).
INSERT INTO orders.idempotency_keys (key, request_hash, status)
VALUES (:key, :hash, 'PENDING')
ON CONFLICT (key) DO NOTHING
RETURNING key;

-- O2. Existing key: decide replay / in-progress / mismatch in the service.
SELECT status, request_hash, response_code, response_body
FROM orders.idempotency_keys WHERE key = :key;

-- O3. Re-claim a FAILED key on client retry (same body only).
UPDATE orders.idempotency_keys
   SET status = 'PENDING', updated_at = now()
 WHERE key = :key AND status = 'FAILED' AND request_hash = :hash
RETURNING key;

-- O4. Commit step (single transaction): order + items + outbox + key completion.
WITH o AS (
  INSERT INTO orders.orders (cell, customer_id, status, total_paise, reservation_id)
  VALUES (:cell, :customer_id, 'CONFIRMED', :total_paise, :key)
  RETURNING id, created_at
)
INSERT INTO orders.outbox (aggregate, aggregate_id, event_type, payload)
SELECT 'order', o.id, 'order.created',
       jsonb_build_object('order_id', o.id, 'reservation_id', :key, 'cell', :cell, 'total_paise', :total_paise)
FROM o
RETURNING aggregate_id;
-- then: INSERT order_items ...; UPDATE idempotency_keys SET status='COMPLETED', order_id=..., response_* ...

-- O5. Outbox relay batch — several relays can run safely.
SELECT id, event_type, payload
FROM orders.outbox
WHERE published_at IS NULL
ORDER BY created_at
LIMIT 100
FOR UPDATE SKIP LOCKED;
-- after XADD succeeds:
UPDATE orders.outbox SET published_at = now(), attempts = attempts + 1 WHERE id = ANY(:ids);

-- O6. Sweeps (scheduled): expire keys after 24 h, trim published outbox after 7 days.
DELETE FROM orders.idempotency_keys WHERE created_at < now() - interval '24 hours' AND status <> 'PENDING';
DELETE FROM orders.outbox WHERE published_at < now() - interval '7 days';

-- O7. Stuck PENDING keys (> 2 min) → mark FAILED so clients can retry (the reservation will be reaped).
UPDATE orders.idempotency_keys SET status = 'FAILED', updated_at = now()
 WHERE status = 'PENDING' AND updated_at < now() - interval '2 minutes';
```

## inventory schema (inventory-service)

```sql
-- services/inventory-service/src/main/resources/db/migration/V1__inventory.sql
CREATE SCHEMA IF NOT EXISTS inventory;
SET search_path TO inventory;

CREATE TABLE products (
    sku          text PRIMARY KEY,
    name         text NOT NULL,
    price_paise  bigint NOT NULL CHECK (price_paise >= 0)
);

-- The cell's escrow lease per SKU, granted by the control-plane allocator.
CREATE TABLE inventory_lease (
    sku          text        PRIMARY KEY REFERENCES products(sku),
    granted_qty  int         NOT NULL CHECK (granted_qty >= 0),
    sold_qty     int         NOT NULL DEFAULT 0 CHECK (sold_qty >= 0),
    lease_epoch  bigint      NOT NULL,                          -- fencing token, strictly increasing
    expires_at   timestamptz NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT never_oversell CHECK (sold_qty <= granted_qty)
);

CREATE TABLE reservations (
    reservation_id uuid        PRIMARY KEY,                     -- = order Idempotency-Key
    sku            text        NOT NULL REFERENCES products(sku),
    qty            int         NOT NULL CHECK (qty > 0),
    status         text        NOT NULL CHECK (status IN ('HELD', 'CONFIRMED', 'RELEASED')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reservations_held ON reservations (created_at) WHERE status = 'HELD';
```
(Multi-SKU orders: one reservation row per SKU with a composite key `(reservation_id, sku)` — shown single-SKU for clarity; switch the PK when you add carts.)

### Queries (inventory-service)

```sql
-- I1. Idempotent reserve (one transaction). If the reservation already exists, return it unchanged.
WITH existing AS (
  SELECT reservation_id, status FROM inventory.reservations WHERE reservation_id = :rid
), dec AS (
  UPDATE inventory.inventory_lease
     SET sold_qty = sold_qty + :qty, updated_at = now()
   WHERE sku = :sku
     AND NOT EXISTS (SELECT 1 FROM existing)
     AND expires_at > now()
     AND sold_qty + :qty <= granted_qty
  RETURNING sku
), ins AS (
  INSERT INTO inventory.reservations (reservation_id, sku, qty, status)
  SELECT :rid, :sku, :qty, 'HELD' FROM dec
  RETURNING reservation_id, status
)
SELECT reservation_id, status, 'created' AS outcome FROM ins
UNION ALL
SELECT reservation_id, status, 'replayed' FROM existing;
-- 0 rows → out of stock in this cell (or lease expired) → 409

-- I2. Confirm on order.created (consumer of stream:cell-events; idempotent).
UPDATE inventory.reservations SET status = 'CONFIRMED', updated_at = now()
 WHERE reservation_id = :rid AND status = 'HELD';

-- I3. Reaper: release HELD reservations older than 15 min and give the quantity back (one transaction).
WITH expired AS (
  UPDATE inventory.reservations SET status = 'RELEASED', updated_at = now()
   WHERE status = 'HELD' AND created_at < now() - interval '15 minutes'
  RETURNING sku, qty
), per_sku AS (
  SELECT sku, sum(qty) AS qty FROM expired GROUP BY sku
)
UPDATE inventory.inventory_lease l
   SET sold_qty = l.sold_qty - p.qty, updated_at = now()
  FROM per_sku p
 WHERE l.sku = p.sku;

-- I4. Apply a lease grant from the allocator — fencing: only a strictly newer epoch wins.
INSERT INTO inventory.inventory_lease (sku, granted_qty, sold_qty, lease_epoch, expires_at)
VALUES (:sku, :granted, 0, :epoch, :expires_at)
ON CONFLICT (sku) DO UPDATE
   SET granted_qty = EXCLUDED.granted_qty + inventory.inventory_lease.sold_qty,  -- grant is for *remaining* stock
       lease_epoch = EXCLUDED.lease_epoch,
       expires_at  = EXCLUDED.expires_at,
       updated_at  = now()
 WHERE inventory.inventory_lease.lease_epoch < EXCLUDED.lease_epoch
RETURNING lease_epoch;
-- 0 rows → stale grant (older epoch) → reject with 409 and log: that's the fence working

-- I5. Renewal report sent to the allocator every 5 min.
SELECT sku, granted_qty, sold_qty, lease_epoch, expires_at FROM inventory.inventory_lease;

-- I6. Cache-aside read model (Valkey key inv:{sku}, TTL 30 s + jitter).
SELECT sku, greatest(granted_qty - sold_qty, 0) AS sellable_in_cell, expires_at > now() AS lease_valid
FROM inventory.inventory_lease WHERE sku = :sku;
```

### Why `granted_qty + sold_qty` in I4
The allocator grants the quantity the cell may **still** sell. Storing `granted_qty` as a running total keeps the `CHECK (sold_qty <= granted_qty)` invariant meaningful across renewals without resetting `sold_qty` (which would lose the audit trail). Explain this choice in a code comment; it is the kind of detail interviewers probe.

## Roles

```sql
CREATE ROLE order_svc LOGIN;        GRANT USAGE ON SCHEMA orders TO order_svc;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO order_svc;
CREATE ROLE inventory_svc LOGIN;    GRANT USAGE ON SCHEMA inventory TO inventory_svc;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA inventory TO inventory_svc;
CREATE ROLE parity_reader LOGIN;    -- used by the parity checker for flyway_schema_history only
GRANT USAGE ON SCHEMA orders, inventory TO parity_reader;
GRANT SELECT ON orders.flyway_schema_history, inventory.flyway_schema_history TO parity_reader;
```
(The `flyway_schema_history` tables exist after the first migration; run the grants in a later migration or an `afterMigrate` callback.)
