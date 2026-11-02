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

-- One row per (order, sku): reservation_id is the order's Idempotency-Key, so multi-line orders
-- reserve each SKU under the same id and a replay of any line is recognised.
CREATE TABLE reservations (
    reservation_id uuid        NOT NULL,                        -- = order Idempotency-Key
    sku            text        NOT NULL REFERENCES products(sku),
    qty            int         NOT NULL CHECK (qty > 0),
    status         text        NOT NULL CHECK (status IN ('HELD', 'CONFIRMED', 'RELEASED')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (reservation_id, sku)
);
CREATE INDEX reservations_held ON reservations (created_at) WHERE status = 'HELD';
```
Orders carry up to 50 lines, so the composite key is the implemented layout (services/inventory-service V1).

### Queries (inventory-service)

```sql
-- I1. Idempotent reserve (one transaction, per (reservation id, sku)).
-- First clear a RELEASED line (compensated or reaped): otherwise a client retry under the same
-- Idempotency-Key would "replay" a line that no longer holds stock.
DELETE FROM inventory.reservations WHERE reservation_id = :rid AND sku = :sku AND status = 'RELEASED';
WITH existing AS (
  SELECT reservation_id, status FROM inventory.reservations WHERE reservation_id = :rid AND sku = :sku
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
-- Two concurrent first attempts with the same id: the second waits on the lease row lock, then hits
-- the primary key; its whole transaction (decrement included) rolls back with DuplicateKeyException
-- and the controller retries once, which now returns 'replayed'.

-- I1b. Compensation (order-service saw a later line out of stock, or inventory timed out):
-- give back every HELD line of the reservation. Idempotent.
WITH rel AS (
  UPDATE inventory.reservations SET status = 'RELEASED', updated_at = now()
   WHERE reservation_id = :rid AND status = 'HELD'
  RETURNING sku, qty
)
UPDATE inventory.inventory_lease l
   SET sold_qty = l.sold_qty - rel.qty, updated_at = now()
  FROM rel
 WHERE l.sku = rel.sku;

-- I2. Confirm: called directly by order-service right after its commit (fast path) AND by the
--     order.created consumer of stream:cell-events (durable path). Idempotent.
UPDATE inventory.reservations SET status = 'CONFIRMED', updated_at = now()
 WHERE reservation_id = :rid AND status = 'HELD';

-- I3. Reaper: release HELD reservations older than 15 min and give the quantity back (one transaction).
--     Residual risk (state it): if BOTH confirm paths fail for longer than the hold window, a committed
--     order's line is released and the cell may sell that unit again. Alert on outbox lag.
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
INSERT INTO inventory.inventory_lease AS l (sku, granted_qty, sold_qty, lease_epoch, expires_at)
VALUES (:sku, :reported_sold + :remaining, 0, :epoch, :expires_at)
ON CONFLICT (sku) DO UPDATE
   SET granted_qty = GREATEST(l.sold_qty, EXCLUDED.granted_qty),  -- computed from the sold_qty the allocator saw
       lease_epoch = EXCLUDED.lease_epoch,
       expires_at  = EXCLUDED.expires_at,
       updated_at  = now()
 WHERE l.lease_epoch < EXCLUDED.lease_epoch
RETURNING lease_epoch, granted_qty;
-- 0 rows → stale grant (older epoch) → reject with 409 and log: that's the fence working

-- I5. Renewal report sent to the allocator every 5 min.
SELECT sku, granted_qty, sold_qty, lease_epoch, expires_at FROM inventory.inventory_lease;

-- I6. Cache-aside read model (Valkey key inv:{sku}, TTL 30 s + jitter).
SELECT sku, greatest(granted_qty - sold_qty, 0) AS sellable_in_cell, expires_at > now() AS lease_valid
FROM inventory.inventory_lease WHERE sku = :sku;
```

### Why a running total, from the reported sold, in I4
The allocator grants the quantity the cell may **still** sell. Storing `granted_qty` as a running total keeps the `CHECK (sold_qty <= granted_qty)` invariant meaningful across renewals without resetting `sold_qty` (which would lose the audit trail). The total starts from the `sold_qty` the allocator saw in its report, not the current one, so sales made while the grant travelled come out of the grant instead of adding to it; `GREATEST` keeps the CHECK true when the cell already sold past the new total. Explain this choice in a code comment; it is the kind of detail interviewers probe.

## Roles

Migrations `order-service/V2__roles.sql` and `inventory-service/V3__roles.sql` create `order_svc`, `inventory_svc`, `parity_reader` and `health_reader`. Roles are per Postgres cluster and both services migrate at once, so each `CREATE ROLE` tolerates `duplicate_object` and `unique_violation`. The service roles get DML on their own schema (and future tables, via default privileges) but no write on `flyway_schema_history`; `parity_reader` reads only `flyway_schema_history`; `health_reader` reads nothing and only runs `SELECT 1`.

**Not wired yet:** the roles have no password, so nothing logs in as them, and services still use the owner credentials from `cell-db`. Using them needs per-role passwords in the cell's secret tooling, and a separate owner credential for Flyway.
