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
