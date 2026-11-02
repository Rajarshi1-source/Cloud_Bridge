-- Least-privilege roles for this schema. They are created without a password, so nothing can log in
-- as them until the cell's secret tooling sets one; services keep the owner credentials until then.
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['inventory_svc', 'parity_reader', 'health_reader'] LOOP
        BEGIN
            EXECUTE format('CREATE ROLE %I LOGIN', r);
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- the other service got there first (roles are per Postgres cluster, migrations run concurrently)
        END;
    END LOOP;
END $$;

GRANT USAGE ON SCHEMA inventory TO inventory_svc;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA inventory TO inventory_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA inventory GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO inventory_svc;
REVOKE INSERT, UPDATE, DELETE ON inventory.flyway_schema_history FROM inventory_svc;

-- The parity checker compares migration levels and reads nothing else.
GRANT USAGE ON SCHEMA inventory TO parity_reader;
GRANT SELECT ON inventory.flyway_schema_history TO parity_reader;
