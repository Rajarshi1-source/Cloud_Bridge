-- Control-plane tables the allocator owns. Idempotent, applied at start-up; moves into the control
-- plane's migrations when that schema arrives (Week 6, cloudbridge-finops-steering).
CREATE TABLE IF NOT EXISTS stock (
    sku       text PRIMARY KEY,
    total_qty int  NOT NULL CHECK (total_qty >= 0)
);

-- One row per grant a cell confirmed. granted_qty is the cell's running total (reported_sold + what
-- it may still sell), so the row alone says what that cell could have sold while unreachable.
CREATE TABLE IF NOT EXISTS lease_grants (
    cell_id       text        NOT NULL,
    sku           text        NOT NULL REFERENCES stock (sku),
    epoch         bigint      NOT NULL,
    granted_qty   int         NOT NULL,
    expires_at    timestamptz NOT NULL,
    reported_sold int         NOT NULL,
    at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (cell_id, sku, epoch)
);
