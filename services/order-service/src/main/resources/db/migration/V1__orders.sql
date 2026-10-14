-- orders schema, owned by order-service. Expand-only from here on: every later migration must
-- work with the previous app version (two cells can run adjacent versions for up to two hours).
CREATE SCHEMA IF NOT EXISTS orders;
SET search_path TO orders;

CREATE TABLE orders (
    id             uuid        PRIMARY KEY DEFAULT uuidv7(),     -- PG18 built-in: time-ordered, no coordination
    cell           text        NOT NULL,                         -- provenance, e.g. 'cb-gcp-prod'
    customer_id    uuid        NOT NULL,
    status         text        NOT NULL CHECK (status IN ('CONFIRMED', 'CANCELLED')),
    total_paise    bigint      NOT NULL CHECK (total_paise >= 0), -- money as integer paise, never double
    currency       char(3)     NOT NULL DEFAULT 'INR',
    reservation_id uuid        NOT NULL UNIQUE,                  -- = Idempotency-Key = inventory reservation id
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_created ON orders (customer_id, created_at DESC);

CREATE TABLE order_items (
    order_id    uuid   NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    sku         text   NOT NULL,
    qty         int    NOT NULL CHECK (qty > 0),
    price_paise bigint NOT NULL CHECK (price_paise >= 0),
    PRIMARY KEY (order_id, sku)
);

-- A retried POST (client retry, gateway retry, failover mid-request) returns the original result.
CREATE TABLE idempotency_keys (
    key            uuid        PRIMARY KEY,
    request_hash   text        NOT NULL,                         -- sha256 of the canonical request body
    status         text        NOT NULL CHECK (status IN ('PENDING', 'COMPLETED', 'FAILED')),
    order_id       uuid        REFERENCES orders(id),
    response_code  int,
    response_body  jsonb,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idempotency_created ON idempotency_keys (created_at);

-- Transactional outbox: events are written in the same transaction as the state change and relayed
-- to the Valkey stream afterwards. No dual write.
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
