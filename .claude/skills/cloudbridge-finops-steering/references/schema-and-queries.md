# Control-Plane Schema & Queries (PostgreSQL 18)

Applied with Flyway from `control-plane/migrations/`. The control-plane DB is separate from each cell's DB (cell schema lives in cloudbridge-cell-services).

## Contents
1. Types, cells, services
2. Deployments and traffic changes (+ weights trigger)
3. FOCUS ledger (partitioned), ingestions, allocation, request volumes
4. Parity, drills, steering, plan-risk
5. Partition maintenance
6. Queries (dashboard, reconciliation, recommender inputs, drills, parity)
7. Roles and retention

---

## 1. Types, cells, services

```sql
-- V1__base.sql
CREATE TYPE cloud_t   AS ENUM ('aws', 'gcp');
CREATE TYPE profile_t AS ENUM ('managed', 'budget');

CREATE TABLE cells (
    id          text PRIMARY KEY,                       -- 'cb-aws-prod'
    cloud       cloud_t   NOT NULL,
    profile     profile_t NOT NULL,
    env         text      NOT NULL,
    region      text      NOT NULL,
    stack_path  text      NOT NULL,                     -- infra/live/aws-prod
    shape       jsonb     NOT NULL,                     -- {vcpu, mem_gib, class, instance_type}
    status      text      NOT NULL DEFAULT 'unknown' CHECK (status IN ('unknown','healthy','degraded','drained','down')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE services (
    name   text PRIMARY KEY,                            -- 'order-service'
    repo   text NOT NULL                                -- '<you>/cb-order-service'
);

INSERT INTO services (name, repo) VALUES
  ('api-gateway', 'cb-api-gateway'), ('order-service', 'cb-order-service'), ('inventory-service', 'cb-inventory-service');
```

## 2. Deployments and traffic changes

```sql
-- V2__deployments_traffic.sql
CREATE TABLE deployments (
    id            uuid PRIMARY KEY DEFAULT uuidv7(),
    cell_id       text NOT NULL REFERENCES cells(id),
    kind          text NOT NULL CHECK (kind IN ('infra', 'release', 'traffic')),
    stack         text,
    engine        text,                                 -- 'terraform 1.15.2'
    plan_sha256   text,
    changes       jsonb,                                -- {"add":1,"change":2,"destroy":0}
    image_digests jsonb,
    commit_sha    text NOT NULL,
    pr_number     int,
    run_id        bigint,
    status        text NOT NULL CHECK (status IN ('planned','approved','applied','failed','rolled_back')),
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz
);
CREATE INDEX deployments_cell_time ON deployments (cell_id, started_at DESC);

CREATE TABLE traffic_changes (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    weights     jsonb NOT NULL,                         -- {"aws":70,"gcp":30}
    source      text  NOT NULL CHECK (source IN ('manual','recommender','evacuation','failback','drill','break_glass')),
    pr_url      text,
    drill_id    uuid,
    applied_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX traffic_changes_time ON traffic_changes (applied_at DESC);

-- CHECK constraints can't hold subqueries → enforce "sum = 100, each 0 or >= 10" with a trigger
CREATE FUNCTION traffic_weights_valid() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  total int;
  bad   int;
BEGIN
  SELECT sum(value::int), count(*) FILTER (WHERE value::int NOT IN (0) AND value::int < 10)
    INTO total, bad
    FROM jsonb_each_text(NEW.weights);
  IF total <> 100 THEN
    RAISE EXCEPTION 'traffic weights must sum to 100, got % (%)', total, NEW.weights;
  END IF;
  IF bad > 0 THEN
    RAISE EXCEPTION 'each weight must be 0 or >= 10 (warm floor): %', NEW.weights;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER traffic_weights_valid BEFORE INSERT OR UPDATE ON traffic_changes
  FOR EACH ROW EXECUTE FUNCTION traffic_weights_valid();
```

## 3. FOCUS ledger, ingestions, allocation, volumes

```sql
-- V3__ledger.sql
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
```

## 4. Parity, drills, steering, plan-risk

```sql
-- V4__parity_drills.sql
CREATE TABLE parity_snapshots (
    id         uuid PRIMARY KEY DEFAULT uuidv7(),
    env        text NOT NULL,
    score      numeric(5,4) NOT NULL CHECK (score BETWEEN 0 AND 1),
    passed     boolean NOT NULL,
    trigger    text NOT NULL CHECK (trigger IN ('pr','post_sync','nightly','manual')),
    commit_sha text,
    taken_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX parity_env_time ON parity_snapshots (env, taken_at DESC);

CREATE TABLE parity_findings (
    snapshot_id       uuid NOT NULL REFERENCES parity_snapshots(id) ON DELETE CASCADE,
    check_id          text NOT NULL,
    weight            numeric(4,2) NOT NULL,
    cell_values       jsonb NOT NULL,                     -- {"cb-aws-prod": ..., "cb-gcp-prod": ...} ("values" is reserved)
    status            text NOT NULL CHECK (status IN ('match','diverged','excepted','unknown')),
    exception_expires date,
    PRIMARY KEY (snapshot_id, check_id)
);

CREATE TABLE drills (
    id               uuid PRIMARY KEY DEFAULT uuidv7(),
    env              text NOT NULL,
    from_cell        text NOT NULL REFERENCES cells(id),
    to_cell          text NOT NULL REFERENCES cells(id),
    mode             text NOT NULL CHECK (mode IN ('drill','real')),
    outcome          text NOT NULL DEFAULT 'running' CHECK (outcome IN ('running','completed','aborted','rolled_back')),
    original_weights jsonb,
    capacity_ratio   numeric(6,3),
    capacity_ratio_after_prewarm numeric(6,3),
    prewarm_seconds  int,
    shift_seconds    int,
    errors_during    bigint,
    burn_rate_max    numeric(8,3),
    report_path      text,
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    CHECK (from_cell <> to_cell)
);
CREATE INDEX drills_time ON drills (started_at DESC);

CREATE TABLE drill_steps (
    drill_id   uuid NOT NULL REFERENCES drills(id) ON DELETE CASCADE,
    seq        int  NOT NULL,
    weights    jsonb NOT NULL,
    burn_rate  numeric(8,3),
    p95_ms     numeric(10,2),
    decision   text NOT NULL CHECK (decision IN ('advance','hold','abort')),
    at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (drill_id, seq)
);

-- V5__steering_planrisk.sql
CREATE TABLE steering_recommendations (
    id                   uuid PRIMARY KEY DEFAULT uuidv7(),
    current_weights      jsonb NOT NULL,
    proposed             jsonb NOT NULL,
    est_saving_inr_month numeric(12,2),
    binding_constraint   text,
    model                jsonb NOT NULL,              -- {"aws":{"fixed":..,"marginal":..},"gcp":{...}}
    backtest             jsonb NOT NULL,              -- {"days":90,"slo_violations":0,"saving_vs_static_pct":..}
    data_as_of           timestamptz NOT NULL,
    pr_url               text,
    decided              text NOT NULL DEFAULT 'pending' CHECK (decided IN ('merged','closed','pending')),
    created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE plan_risk_reports (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    pr_number   int  NOT NULL,
    stack       text NOT NULL,
    plan_sha256 text NOT NULL,
    verdict     text NOT NULL CHECK (verdict IN ('pass','warn','block')),
    overridden  boolean NOT NULL DEFAULT false,       -- allow-destructive label present
    findings    jsonb NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

## 5. Partition maintenance

```sql
-- V6__partitions.sql — called daily by the collector before ingesting
CREATE FUNCTION ensure_cost_partitions(months_ahead int DEFAULT 2) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  m date := date_trunc('month', now() - interval '13 months')::date;
  stop date := (date_trunc('month', now()) + make_interval(months => months_ahead))::date;
  part text;
BEGIN
  WHILE m <= stop LOOP
    part := format('cost_line_items_%s', to_char(m, 'YYYY_MM'));
    IF to_regclass(part) IS NULL THEN
      EXECUTE format('CREATE TABLE %I PARTITION OF cost_line_items FOR VALUES FROM (%L) TO (%L)',
                     part, m, (m + interval '1 month')::date);
    END IF;
    m := (m + interval '1 month')::date;
  END LOOP;
END $$;

SELECT ensure_cost_partitions();
-- Archival: partitions older than 13 months are DETACHed, COPYed to Parquet in object storage, then dropped.
```
A default partition is deliberately **not** created: a row outside every range should fail the ingestion loudly rather than land somewhere unindexed.

## 6. Queries

```sql
-- Q1. Cost per 1,000 requests per service per cell (headline panel)
--     Directly tagged costs (cb-service set: DB, cache, LB) attach to that service;
--     untagged-to-service cell costs (nodes, NAT, control plane) split by OpenCost CPU share.
WITH params AS (
  SELECT current_date - 30 AS since, current_date AS until
),
direct AS (
  SELECT c.cb_cell AS cell_id, c.cb_service AS service, sum(c.effective_cost) AS cost
  FROM cost_line_items c, params p
  WHERE c.charge_category = 'Usage' AND c.cb_service IS NOT NULL
    AND c.charge_period_start >= p.since AND c.charge_period_start < p.until
  GROUP BY 1, 2
),
shared_daily AS (
  SELECT c.cb_cell AS cell_id, c.charge_period_start::date AS day, sum(c.effective_cost) AS cost
  FROM cost_line_items c, params p
  WHERE c.charge_category = 'Usage' AND c.cb_cell IS NOT NULL AND c.cb_service IS NULL
    AND c.charge_period_start >= p.since AND c.charge_period_start < p.until
  GROUP BY 1, 2
),
shared AS (
  SELECT s.cell_id, a.service, sum(s.cost * a.cpu_share) AS cost
  FROM shared_daily s
  JOIN allocation_daily a ON a.cell_id = s.cell_id AND a.day = s.day
  GROUP BY 1, 2
),
vol AS (
  SELECT cell_id, service, sum(requests) AS req
  FROM request_volume_daily, params p
  WHERE day >= p.since AND day < p.until
  GROUP BY 1, 2
)
SELECT v.cell_id, v.service,
       round(coalesce(d.cost, 0) + coalesce(s.cost, 0), 2)                                  AS cost_30d,
       v.req                                                                                AS requests_30d,
       round((coalesce(d.cost, 0) + coalesce(s.cost, 0)) / nullif(v.req, 0) * 1000, 6)      AS cost_per_1k_req
FROM vol v
LEFT JOIN direct d USING (cell_id, service)
LEFT JOIN shared s USING (cell_id, service)
ORDER BY v.service, v.cell_id;

-- Q2. Unallocated cost (no cb-cell tag) — must be visible, never spread silently
SELECT provider_name, service_name, round(sum(effective_cost), 2) AS cost
FROM cost_line_items
WHERE charge_category = 'Usage' AND cb_cell IS NULL
  AND charge_period_start >= current_date - 30
GROUP BY 1, 2 ORDER BY cost DESC LIMIT 20;

-- Q3. OpenCost estimate vs bill — reconciliation error per cell per day
WITH bill AS (
  SELECT cb_cell AS cell_id, charge_period_start::date AS day, sum(effective_cost) AS billed
  FROM cost_line_items
  WHERE charge_category = 'Usage' AND cb_cell IS NOT NULL
  GROUP BY 1, 2
), est AS (
  SELECT cell_id, day, sum(opencost_estimate) AS estimated
  FROM allocation_daily GROUP BY 1, 2
)
SELECT e.day, e.cell_id, round(e.estimated, 2) AS estimated, round(b.billed, 2) AS billed,
       round(100 * (e.estimated / nullif(b.billed, 0) - 1), 2) AS error_pct
FROM est e JOIN bill b USING (cell_id, day)
ORDER BY e.day DESC, e.cell_id;

-- Q4. Billing data freshness per provider (shown on every cost panel)
SELECT provider_name, max(period_start) AS latest_day,
       now() - max(ingested_at) AS since_ingest
FROM cost_ingestions GROUP BY 1;

-- Q5. Recommender inputs: daily cost and requests per cell (28 days)
SELECT r.day, r.cell_id,
       sum(r.requests)                                                   AS requests,
       (SELECT sum(c.effective_cost) FROM cost_line_items c
         WHERE c.cb_cell = r.cell_id AND c.charge_category = 'Usage'
           AND c.charge_period_start >= r.day AND c.charge_period_start < r.day + 1) AS cost,
       max(r.p95_ms) FILTER (WHERE r.service = 'api-gateway')            AS gateway_p95_ms
FROM request_volume_daily r
WHERE r.day >= current_date - 28
GROUP BY r.day, r.cell_id
ORDER BY r.day, r.cell_id;

-- Q6. Configured traffic weights over time (for the configured-vs-observed panel)
SELECT applied_at, (weights->>'aws')::int AS aws, (weights->>'gcp')::int AS gcp, source
FROM traffic_changes ORDER BY applied_at DESC LIMIT 50;

-- Q7. Drill history — the exit-plan evidence table
SELECT started_at::date AS day, from_cell, to_cell, mode, outcome,
       capacity_ratio, capacity_ratio_after_prewarm, prewarm_seconds, shift_seconds,
       errors_during, burn_rate_max, report_path
FROM drills ORDER BY started_at DESC LIMIT 20;

-- Q8. Parity: latest snapshot per env with its divergences
SELECT DISTINCT ON (s.env) s.env, s.score, s.passed, s.taken_at,
       (SELECT jsonb_agg(jsonb_build_object('check', f.check_id, 'status', f.status, 'values', f.cell_values))
          FROM parity_findings f WHERE f.snapshot_id = s.id AND f.status IN ('diverged','unknown')) AS problems
FROM parity_snapshots s
ORDER BY s.env, s.taken_at DESC;

-- Q9. Exceptions expiring within 7 days (from the latest snapshots)
SELECT s.env, f.check_id, f.exception_expires
FROM parity_findings f JOIN parity_snapshots s ON s.id = f.snapshot_id
WHERE f.status = 'excepted' AND f.exception_expires <= current_date + 7
  AND s.taken_at > now() - interval '1 day';
```
`date + int` (`r.day + 1`) is valid for `date` columns in PostgreSQL. Q1 is the one to explain at a whiteboard: direct attribution first, shared cost by measured share, unit cost last.

## 7. Roles and retention

```sql
CREATE ROLE cp_writer LOGIN;      -- collector, API
CREATE ROLE cp_reader LOGIN;      -- dashboard, Grafana datasource
GRANT SELECT ON ALL TABLES IN SCHEMA public TO cp_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cp_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cp_reader;
```
Retention: ledger 13 months hot + archive; `drill_steps`, `parity_findings` 12 months; `traffic_changes`, `drills`, `deployments` kept indefinitely (they are the audit trail). Backups: nightly `pg_dump -Fc` to both S3 and GCS — the control plane's own backups shouldn't live in only one cloud.
