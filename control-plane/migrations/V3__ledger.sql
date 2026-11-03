CREATE TABLE cost_line_items (
    id                   bigint GENERATED ALWAYS AS IDENTITY,
    provider_name        text          NOT NULL,        -- FOCUS ProviderName
    billing_account_id   text          NOT NULL,
    charge_period_start  timestamptz   NOT NULL,
    charge_period_end    timestamptz   NOT NULL,
    charge_category      text          NOT NULL,        -- Usage | Purchase | Tax | Credit | Adjustment
    service_category     text,
    service_name         text,
    resource_id          text,
    region_id            text,
    billed_cost          numeric(18,6) NOT NULL,
    effective_cost       numeric(18,6) NOT NULL,
    list_cost            numeric(18,6),
    billing_currency     char(3)       NOT NULL,
    tags                 jsonb         NOT NULL DEFAULT '{}',
    cb_cell              text GENERATED ALWAYS AS (tags->>'cb-cell') STORED,
    cb_service           text GENERATED ALWAYS AS (tags->>'cb-service') STORED,
    source_file          text          NOT NULL,
    ingested_at          timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (id, charge_period_start)
) PARTITION BY RANGE (charge_period_start);

CREATE INDEX cli_cell_period    ON cost_line_items (cb_cell, charge_period_start);
CREATE INDEX cli_source_file    ON cost_line_items (source_file);
CREATE INDEX cli_tags           ON cost_line_items USING gin (tags);

CREATE TABLE cost_ingestions (
    source_file   text PRIMARY KEY,
    provider_name text NOT NULL,
    period_start  date NOT NULL,
    row_count     int  NOT NULL,
    checksum      text NOT NULL,
    ingested_at   timestamptz NOT NULL DEFAULT now()
);

-- FX: the ledger stores billing currency; dashboards convert at a daily rate you record (RBI reference rate).
CREATE TABLE fx_daily (
    day      date    NOT NULL,
    from_ccy char(3) NOT NULL,
    to_ccy   char(3) NOT NULL DEFAULT 'INR',
    rate     numeric(12,6) NOT NULL,
    source   text NOT NULL,
    PRIMARY KEY (day, from_ccy, to_ccy)
);

CREATE TABLE allocation_daily (
    day               date NOT NULL,
    cell_id           text NOT NULL REFERENCES cells(id),
    service           text NOT NULL REFERENCES services(name),
    cpu_share         numeric(7,6) NOT NULL CHECK (cpu_share BETWEEN 0 AND 1),
    mem_share         numeric(7,6) NOT NULL CHECK (mem_share BETWEEN 0 AND 1),
    opencost_estimate numeric(18,6),
    PRIMARY KEY (day, cell_id, service)
);

CREATE TABLE request_volume_daily (
    day       date   NOT NULL,
    cell_id   text   NOT NULL REFERENCES cells(id),
    service   text   NOT NULL REFERENCES services(name),
    requests  bigint NOT NULL CHECK (requests >= 0),
    errors    bigint NOT NULL CHECK (errors >= 0),
    p95_ms    numeric(10,2),
    PRIMARY KEY (day, cell_id, service)
);
