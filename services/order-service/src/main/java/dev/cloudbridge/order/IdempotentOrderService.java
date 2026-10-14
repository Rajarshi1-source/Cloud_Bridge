package dev.cloudbridge.order;

import dev.cloudbridge.order.OrderModels.Created;
import dev.cloudbridge.order.OrderModels.CreateOrder;
import dev.cloudbridge.order.OrderModels.DependencyUnavailable;
import dev.cloudbridge.order.OrderModels.InProgress;
import dev.cloudbridge.order.OrderModels.Item;
import dev.cloudbridge.order.OrderModels.Mismatch;
import dev.cloudbridge.order.OrderModels.OrderCreated;
import dev.cloudbridge.order.OrderModels.OutOfStock;
import dev.cloudbridge.order.OrderModels.Outcome;
import dev.cloudbridge.order.OrderModels.Replayed;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * POST /orders as a claim → reserve → commit saga. No DB transaction is ever held open across the
 * HTTP call to inventory-service; each step is its own short transaction and every step is
 * idempotent on the client's Idempotency-Key (which is also the inventory reservation id).
 * Idempotency is cell-scoped: a retry that lands in the other cloud is a different cell.
 */
@Service
public class IdempotentOrderService {

	private static final Logger log = LoggerFactory.getLogger(IdempotentOrderService.class);

	private final JdbcClient jdbc;

	private final TransactionTemplate tx;

	private final InventoryClient inventory;

	private final JsonMapper json;

	private final String cell;

	public IdempotentOrderService(JdbcClient jdbc, TransactionTemplate tx, InventoryClient inventory, JsonMapper json,
			@Value("${cloudbridge.cell}") String cell) {
		this.jdbc = jdbc;
		this.tx = tx;
		this.inventory = inventory;
		this.json = json;
		this.cell = cell;
	}

	public Outcome create(UUID key, CreateOrder req) {
		String hash = sha256(this.json.writeValueAsString(req));

		// 1. Claim (own short transaction).
		Optional<Outcome> earlier = claim(key, hash);
		if (earlier.isPresent()) {
			return earlier.get();
		}

		// 2. Reserve every line in this cell's inventory (idempotent: reservation id = key).
		try {
			for (Item item : req.items()) {
				if (!this.inventory.reserve(key, item.sku(), item.qty())) {
					releaseQuietly(key);
					markFailed(key);
					return new OutOfStock(item.sku());
				}
			}
		}
		catch (RuntimeException ex) {
			// Timeout, 5xx or open breaker. Inventory may have reserved some lines: give them back.
			log.warn("reserve for key {} failed: {}", key, ex.toString());
			releaseQuietly(key);
			markFailed(key);
			return new DependencyUnavailable("inventory-service");
		}

		// 3. Commit order + items + outbox + key completion atomically. If this fails the key goes
		// to FAILED and the HELD reservation is kept for the client's retry under the same key
		// (reserve replays); inventory's reaper releases it after 15 min if no retry comes.
		Created created;
		try {
			created = this.tx.execute((status) -> commit(key, req));
		}
		catch (RuntimeException ex) {
			try {
				markFailed(key); // if the DB is down this fails too; the PENDING sweep catches it
			}
			catch (RuntimeException markEx) {
				ex.addSuppressed(markEx);
			}
			throw ex;
		}
		confirmQuietly(key);
		return created;
	}

	private Optional<Outcome> claim(UUID key, String hash) {
		boolean claimed = this.jdbc.sql("""
				INSERT INTO orders.idempotency_keys (key, request_hash, status)
				VALUES (:k, :h, 'PENDING')
				ON CONFLICT (key) DO NOTHING
				RETURNING key""").param("k", key).param("h", hash).query(UUID.class).optional().isPresent();
		if (claimed) {
			return Optional.empty();
		}
		Optional<KeyRow> row = this.jdbc
			.sql("SELECT status, request_hash, response_code, response_body::text FROM orders.idempotency_keys WHERE key = :k")
			.param("k", key)
			.query((rs, n) -> new KeyRow(rs.getString(1), rs.getString(2), rs.getInt(3), rs.getString(4)))
			.optional();
		if (row.isEmpty()) {
			return Optional.of(new InProgress()); // swept between our two statements; client retries
		}
		KeyRow existing = row.get();
		if (!hash.equals(existing.requestHash())) {
			return Optional.of(new Mismatch());
		}
		return switch (existing.status()) {
			case "COMPLETED" -> Optional.of(new Replayed(existing.responseCode(), existing.responseBody()));
			case "PENDING" -> Optional.of(new InProgress());
			default -> { // FAILED: the same body may be retried under the same key
				boolean reclaimed = this.jdbc.sql("""
						UPDATE orders.idempotency_keys SET status = 'PENDING', updated_at = now()
						 WHERE key = :k AND status = 'FAILED' AND request_hash = :h
						RETURNING key""").param("k", key).param("h", hash).query(UUID.class).optional().isPresent();
				yield reclaimed ? Optional.empty() : Optional.of(new InProgress());
			}
		};
	}

	private Created commit(UUID key, CreateOrder req) {
		// orders.id is `uuid PRIMARY KEY DEFAULT uuidv7()` — generated by Postgres 18, never in Java.
		UUID orderId = this.jdbc.sql("""
				INSERT INTO orders.orders (cell, customer_id, status, total_paise, reservation_id)
				VALUES (:cell, :customer, 'CONFIRMED', :total, :key)
				RETURNING id""")
			.param("cell", this.cell)
			.param("customer", req.customerId())
			.param("total", req.totalPaise())
			.param("key", key)
			.query(UUID.class)
			.single();
		for (Item i : req.items()) {
			this.jdbc.sql("INSERT INTO orders.order_items (order_id, sku, qty, price_paise) VALUES (:o, :s, :q, :p)")
				.param("o", orderId)
				.param("s", i.sku())
				.param("q", i.qty())
				.param("p", i.pricePaise())
				.update();
		}
		OrderCreated body = new OrderCreated(orderId, this.cell, "CONFIRMED", req.totalPaise(), "INR");
		String bodyJson = this.json.writeValueAsString(body);
		String event = this.json.writeValueAsString(Map.of("order_id", orderId, "reservation_id", key, "cell",
				this.cell, "total_paise", req.totalPaise()));
		this.jdbc.sql("""
				INSERT INTO orders.outbox (aggregate, aggregate_id, event_type, payload)
				VALUES ('order', :o, 'order.created', CAST(:p AS jsonb))""").param("o", orderId).param("p", event).update();
		this.jdbc.sql("""
				UPDATE orders.idempotency_keys
				   SET status = 'COMPLETED', order_id = :o, response_code = 201,
				       response_body = CAST(:b AS jsonb), updated_at = now()
				 WHERE key = :k""").param("o", orderId).param("b", bodyJson).param("k", key).update();
		return new Created(body, bodyJson);
	}

	private void markFailed(UUID key) {
		this.jdbc.sql("UPDATE orders.idempotency_keys SET status = 'FAILED', updated_at = now() WHERE key = :k")
			.param("k", key)
			.update();
	}

	private void releaseQuietly(UUID key) {
		try {
			this.inventory.release(key);
		}
		catch (RuntimeException ex) {
			log.warn("release of reservation {} failed; inventory's reaper will release it: {}", key, ex.toString());
		}
	}

	private void confirmQuietly(UUID key) {
		try {
			this.inventory.confirm(key);
		}
		catch (RuntimeException ex) {
			log.info("fast-path confirm of {} failed; the order.created event will confirm it: {}", key, ex.toString());
		}
	}

	private static String sha256(String s) {
		try {
			return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8)));
		}
		catch (NoSuchAlgorithmException ex) {
			throw new IllegalStateException(ex); // SHA-256 is mandatory in every JRE
		}
	}

	private record KeyRow(String status, String requestHash, int responseCode, String responseBody) {
	}

}
