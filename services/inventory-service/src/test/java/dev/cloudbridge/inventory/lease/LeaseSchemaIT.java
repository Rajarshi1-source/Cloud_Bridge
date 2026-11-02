package dev.cloudbridge.inventory.lease;

import dev.cloudbridge.inventory.LeaseTestSupport;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.simple.JdbcClient;

import static org.assertj.core.api.Assertions.assertThat;

/** The catalog reaches every cell, the stock does not, and the migration roles stay least-privilege. */
@Import(LeaseTestSupport.class)
@SpringBootTest
class LeaseSchemaIT {

	@Autowired
	JdbcClient jdbc;

	private boolean can(String role, String table, String privilege) {
		return this.jdbc.sql("SELECT has_table_privilege(:r, :t, :p)")
			.param("r", role)
			.param("t", table)
			.param("p", privilege)
			.query(Boolean.class)
			.single();
	}

	@Test
	void catalogIsSeededWithoutAnyLease() {
		assertThat(this.jdbc.sql("SELECT count(*) FROM inventory.products WHERE sku IN ('SKU-1', 'SKU-2')")
			.query(Long.class)
			.single()).isEqualTo(2);
		assertThat(this.jdbc.sql("SELECT count(*) FROM inventory.inventory_lease WHERE sku IN ('SKU-1', 'SKU-2')")
			.query(Long.class)
			.single()).isZero();
	}

	@Test
	void serviceRoleCanWriteItsTablesButNotTheMigrationHistory() {
		assertThat(can("inventory_svc", "inventory.lease_grant_log", "INSERT")).isTrue();
		assertThat(can("inventory_svc", "inventory.flyway_schema_history", "UPDATE")).isFalse();
	}

	@Test
	void readersSeeOnlyWhatTheyNeed() {
		assertThat(can("parity_reader", "inventory.flyway_schema_history", "SELECT")).isTrue();
		assertThat(can("parity_reader", "inventory.products", "SELECT")).isFalse();
		assertThat(can("health_reader", "inventory.products", "SELECT")).isFalse();
	}

}
