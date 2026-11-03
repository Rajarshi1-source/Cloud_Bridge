-- Creating a partition needs ownership of cost_line_items, and the collector's cp_writer must not own it.
ALTER FUNCTION ensure_cost_partitions(int) SECURITY DEFINER SET search_path = public;
REVOKE ALL ON FUNCTION ensure_cost_partitions(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ensure_cost_partitions(int) TO cp_writer;
