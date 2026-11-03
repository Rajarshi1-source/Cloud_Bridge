-- Grafana and the dashboard read through cp_reader; the collector and the API write through cp_writer.
-- Their passwords are set by whatever deploys the database, never here.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cp_reader') THEN CREATE ROLE cp_reader LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cp_writer') THEN CREATE ROLE cp_writer LOGIN; END IF;
END $$;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO cp_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cp_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cp_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cp_writer;
