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
