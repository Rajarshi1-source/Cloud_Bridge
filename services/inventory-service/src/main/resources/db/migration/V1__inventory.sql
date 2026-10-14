-- inventory schema, owned by inventory-service. Expand-only from here on.
CREATE SCHEMA IF NOT EXISTS inventory;
SET search_path TO inventory;

CREATE TABLE products (
    sku          text   PRIMARY KEY,
    name         text   NOT NULL,
    price_paise  bigint NOT NULL CHECK (price_paise >= 0)
);

-- The cell's escrow lease per SKU, granted by the control-plane allocator (admin API: Week 4).
CREATE TABLE inventory_lease (
    sku          text        PRIMARY KEY REFERENCES products(sku),
    granted_qty  int         NOT NULL CHECK (granted_qty >= 0),
    sold_qty     int         NOT NULL DEFAULT 0 CHECK (sold_qty >= 0),
    lease_epoch  bigint      NOT NULL,                          -- fencing token, strictly increasing
    expires_at   timestamptz NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT never_oversell CHECK (sold_qty <= granted_qty)   -- the invariant, enforced by the database
);

-- One row per (order, sku): reservation_id is the order's Idempotency-Key, so multi-line orders
-- reserve each SKU under the same id and a replay of any line is recognised.
CREATE TABLE reservations (
    reservation_id uuid        NOT NULL,
    sku            text        NOT NULL REFERENCES products(sku),
    qty            int         NOT NULL CHECK (qty > 0),
    status         text        NOT NULL CHECK (status IN ('HELD', 'CONFIRMED', 'RELEASED')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (reservation_id, sku)
);
CREATE INDEX reservations_held ON reservations (created_at) WHERE status = 'HELD';
