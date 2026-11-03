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
