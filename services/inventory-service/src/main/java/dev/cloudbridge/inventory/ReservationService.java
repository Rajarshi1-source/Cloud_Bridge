package dev.cloudbridge.inventory;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.resilience.annotation.ConcurrencyLimit;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Escrow reservations against this cell's lease. The lease decrement is ONE conditional UPDATE
 * (no read-modify-write race) and the {@code never_oversell} CHECK backs it up, so concurrent
 * buyers can never take more than the lease grants.
 */
@Service
public class ReservationService {

	public enum Result {

		CREATED, REPLAYED, OUT_OF_STOCK

	}

	private final JdbcClient jdbc;

	public ReservationService(JdbcClient jdbc) {
		this.jdbc = jdbc;
	}

	/**
	 * Idempotent on (reservationId, sku). A RELEASED line (compensated or reaped) is cleared first
	 * so a client retry under the same Idempotency-Key reserves again instead of "replaying" a
	 * line that no longer holds stock. Two concurrent first attempts with the same id: the second
	 * hits the primary key, its whole transaction (including its decrement) rolls back with
	 * DuplicateKeyException, and the caller's retry sees REPLAYED.
	 */
	@Transactional
	@ConcurrencyLimit(32) // bulkhead on the DB-bound hot path
	public Result reserve(UUID rid, String sku, int qty) {
		this.jdbc.sql("""
				DELETE FROM inventory.reservations
				 WHERE reservation_id = :rid AND sku = :sku AND status = 'RELEASED'""")
			.param("rid", rid)
			.param("sku", sku)
			.update();
		return this.jdbc.sql("""
				WITH existing AS (
				  SELECT 1 FROM inventory.reservations WHERE reservation_id = :rid AND sku = :sku
				), dec AS (
				  UPDATE inventory.inventory_lease
				     SET sold_qty = sold_qty + :qty, updated_at = now()
				   WHERE sku = :sku
				     AND NOT EXISTS (SELECT 1 FROM existing)
				     AND expires_at > now()                   -- expired lease: the cell stops selling by itself
				     AND sold_qty + :qty <= granted_qty
				  RETURNING sku
				), ins AS (
				  INSERT INTO inventory.reservations (reservation_id, sku, qty, status)
				  SELECT :rid, :sku, :qty, 'HELD' FROM dec
				  RETURNING reservation_id
				)
				SELECT 'CREATED' FROM ins
				UNION ALL
				SELECT 'REPLAYED' FROM existing""")
			.param("rid", rid)
			.param("sku", sku)
			.param("qty", qty)
			.query(String.class)
			.optional()
			.map(Result::valueOf)
			.orElse(Result.OUT_OF_STOCK);
	}

	/** Compensation from order-service: give back every HELD line. Idempotent; returns lines released. */
	@Transactional
	public int release(UUID rid) {
		return this.jdbc.sql("""
				WITH rel AS (
				  UPDATE inventory.reservations SET status = 'RELEASED', updated_at = now()
				   WHERE reservation_id = :rid AND status = 'HELD'
				  RETURNING sku, qty
				)
				UPDATE inventory.inventory_lease l
				   SET sold_qty = l.sold_qty - rel.qty, updated_at = now()
				  FROM rel
				 WHERE l.sku = rel.sku""").param("rid", rid).update();
	}

	/** I2: the order committed, so its lines are sold for good. Idempotent. */
	@Transactional
	public int confirm(UUID rid) {
		return this.jdbc.sql("""
				UPDATE inventory.reservations SET status = 'CONFIRMED', updated_at = now()
				 WHERE reservation_id = :rid AND status = 'HELD'""").param("rid", rid).update();
	}

	/**
	 * I3: release HELD lines older than the hold window (order never committed) and return the
	 * quantity to the lease. One transaction, so a crash can't release without giving stock back.
	 */
	@Transactional
	public int releaseExpired(int holdMinutes) {
		return this.jdbc.sql("""
				WITH expired AS (
				  UPDATE inventory.reservations SET status = 'RELEASED', updated_at = now()
				   WHERE status = 'HELD' AND created_at < now() - make_interval(mins => :mins)
				  RETURNING sku, qty
				), per_sku AS (
				  SELECT sku, sum(qty) AS qty FROM expired GROUP BY sku
				)
				UPDATE inventory.inventory_lease l
				   SET sold_qty = l.sold_qty - p.qty, updated_at = now()
				  FROM per_sku p
				 WHERE l.sku = p.sku""").param("mins", holdMinutes).update();
	}

}
