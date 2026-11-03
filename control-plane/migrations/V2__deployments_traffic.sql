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
