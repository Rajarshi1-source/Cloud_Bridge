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
