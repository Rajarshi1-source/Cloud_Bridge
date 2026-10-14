package dev.cloudbridge.order;

import dev.cloudbridge.order.OrderModels.ItemView;
import dev.cloudbridge.order.OrderModels.OrderSummary;
import dev.cloudbridge.order.OrderModels.OrderView;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** Cell-local reads. An order created in the other cloud is simply not here (404). */
@Repository
public class OrderQueries {

	private final JdbcClient jdbc;

	public OrderQueries(JdbcClient jdbc) {
		this.jdbc = jdbc;
	}

	public Optional<OrderView> find(UUID id) {
		List<ItemView> items = this.jdbc
			.sql("SELECT sku, qty, price_paise FROM orders.order_items WHERE order_id = :id ORDER BY sku")
			.param("id", id)
			.query((rs, n) -> new ItemView(rs.getString(1), rs.getInt(2), rs.getLong(3)))
			.list();
		return this.jdbc.sql("""
				SELECT id, cell, customer_id, status, total_paise, currency, created_at
				  FROM orders.orders WHERE id = :id""")
			.param("id", id)
			.query((rs, n) -> new OrderView(rs.getObject(1, UUID.class), rs.getString(2), rs.getObject(3, UUID.class),
					rs.getString(4), rs.getLong(5), rs.getString(6), rs.getObject(7, OffsetDateTime.class), items))
			.optional();
	}

	public List<OrderSummary> byCustomer(UUID customerId, int limit) {
		return this.jdbc.sql("""
				SELECT id, status, total_paise, currency, created_at
				  FROM orders.orders WHERE customer_id = :c
				 ORDER BY created_at DESC LIMIT :limit""")
			.param("c", customerId)
			.param("limit", limit)
			.query((rs, n) -> new OrderSummary(rs.getObject(1, UUID.class), rs.getString(2), rs.getLong(3),
					rs.getString(4), rs.getObject(5, OffsetDateTime.class)))
			.list();
	}

}
