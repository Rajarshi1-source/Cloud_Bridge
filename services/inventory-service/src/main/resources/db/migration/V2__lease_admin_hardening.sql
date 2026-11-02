-- Expand only: safe while the previous app version still runs in the other ring.
ALTER TABLE inventory.products
    ADD COLUMN IF NOT EXISTS max_cell_grant int CHECK (max_cell_grant >= 0);   -- NULL → default-max-cell-grant

CREATE TABLE IF NOT EXISTS inventory.lease_grant_log (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    sku           text        NOT NULL,
    epoch         bigint      NOT NULL,
    granted_qty   int         NOT NULL,                 -- remaining quantity as sent by the allocator
    reported_sold int         NOT NULL,                 -- the sold_qty that remaining was computed against
    expires_at    timestamptz NOT NULL,
    actor         text        NOT NULL,                 -- Access JWT common_name (service token Client ID)
    jti           text,
    outcome       text        NOT NULL CHECK (outcome IN
                    ('APPLIED', 'REPLAYED', 'STALE', 'EPOCH_REUSED', 'OUT_OF_BOUNDS', 'UNKNOWN_SKU')),
    rule          text,                                 -- which bound failed, for OUT_OF_BOUNDS
    received_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lease_grant_log_applied ON inventory.lease_grant_log (sku, epoch) WHERE outcome = 'APPLIED';
CREATE INDEX IF NOT EXISTS lease_grant_log_received ON inventory.lease_grant_log (received_at);   -- 30-day sweep
