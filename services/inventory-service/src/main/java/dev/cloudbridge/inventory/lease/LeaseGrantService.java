package dev.cloudbridge.inventory.lease;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Clock;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.Optional;

/** Bounds every grant, even an authenticated one: a buggy allocator must not be able to break the cell. */
@Service
public class LeaseGrantService {

	public record Grant(String sku, int remainingQty, int reportedSold, long epoch, OffsetDateTime expiresAt) {
	}

	public enum Outcome {

		APPLIED, REPLAYED, STALE, EPOCH_REUSED, OUT_OF_BOUNDS, UNKNOWN_SKU

	}

	public record Result(Outcome outcome, String rule, long epoch, int grantedQty) {
	}

	private record Lease(long epoch, int granted) {
	}

	private final JdbcClient jdbc;

	private final Clock clock;

	private final long maxEpochJump;

	private final Duration maxLeaseTtl;

	private final int defaultMaxCellGrant;

	LeaseGrantService(JdbcClient jdbc, Clock clock, @Value("${cloudbridge.lease.max-epoch-jump}") long maxEpochJump,
			@Value("${cloudbridge.lease.max-ttl}") Duration maxLeaseTtl,
			@Value("${cloudbridge.lease.default-max-cell-grant}") int defaultMaxCellGrant) {
		this.jdbc = jdbc;
		this.clock = clock;
		this.maxEpochJump = maxEpochJump;
		this.maxLeaseTtl = maxLeaseTtl;
		this.defaultMaxCellGrant = defaultMaxCellGrant;
	}

	@Transactional
	public Result apply(Grant g, String actor, String jti) {
		Result r = decideAndApply(g);
		this.jdbc.sql("""
				INSERT INTO inventory.lease_grant_log
				    (sku, epoch, granted_qty, reported_sold, expires_at, actor, jti, outcome, rule)
				VALUES (:sku, :epoch, :qty, :sold, :exp, :actor, :jti, :outcome, :rule)""")
			.param("sku", g.sku())
			.param("epoch", g.epoch())
			.param("qty", g.remainingQty())
			.param("sold", g.reportedSold())
			.param("exp", g.expiresAt())
			.param("actor", actor)
			.param("jti", jti)
			.param("outcome", r.outcome().name())
			.param("rule", r.rule())
			.update();
		return r;
	}

	private Result decideAndApply(Grant g) {
		Optional<Integer> cap = this.jdbc
			.sql("SELECT coalesce(max_cell_grant, :dflt) FROM inventory.products WHERE sku = :sku")
			.param("dflt", this.defaultMaxCellGrant)
			.param("sku", g.sku())
			.query(Integer.class)
			.optional();
		if (cap.isEmpty()) {
			return new Result(Outcome.UNKNOWN_SKU, "sku", 0, 0);
		}

		// Lock the lease row so concurrent grants for one SKU serialise.
		Lease current = this.jdbc
			.sql("SELECT lease_epoch, granted_qty FROM inventory.inventory_lease WHERE sku = :sku FOR UPDATE")
			.param("sku", g.sku())
			.query((rs, n) -> new Lease(rs.getLong("lease_epoch"), rs.getInt("granted_qty")))
			.optional()
			.orElse(new Lease(0, 0));

		if (g.epoch() == current.epoch() && current.epoch() > 0) {
			boolean same = this.jdbc.sql("""
					SELECT count(*) > 0 FROM inventory.lease_grant_log
					 WHERE sku = :sku AND epoch = :epoch AND outcome = 'APPLIED'
					   AND granted_qty = :qty AND reported_sold = :sold AND expires_at = :exp""")
				.param("sku", g.sku())
				.param("epoch", g.epoch())
				.param("qty", g.remainingQty())
				.param("sold", g.reportedSold())
				.param("exp", g.expiresAt())
				.query(Boolean.class)
				.single();
			return new Result(same ? Outcome.REPLAYED : Outcome.EPOCH_REUSED, null, current.epoch(), current.granted());
		}
		if (g.epoch() < current.epoch()) {
			return new Result(Outcome.STALE, null, current.epoch(), current.granted());
		}
		if (g.epoch() < 1) {
			return new Result(Outcome.OUT_OF_BOUNDS, "epoch-positive", current.epoch(), current.granted());
		}
		if (g.epoch() > current.epoch() + this.maxEpochJump) {
			return new Result(Outcome.OUT_OF_BOUNDS, "epoch-jump", current.epoch(), current.granted());
		}

		OffsetDateTime now = OffsetDateTime.now(this.clock);
		if (!g.expiresAt().isAfter(now) || g.expiresAt().isAfter(now.plus(this.maxLeaseTtl))) {
			return new Result(Outcome.OUT_OF_BOUNDS, "ttl", current.epoch(), current.granted());
		}
		if (g.remainingQty() < 0 || g.remainingQty() > cap.get()) {
			return new Result(Outcome.OUT_OF_BOUNDS, "quantity", current.epoch(), current.granted());
		}
		// A cell cannot have sold more than it was ever granted, so a larger figure is not from its report.
		if (g.reportedSold() < 0 || g.reportedSold() > current.granted()) {
			return new Result(Outcome.OUT_OF_BOUNDS, "reported-sold", current.epoch(), current.granted());
		}

		// granted_qty is a running total, so CHECK (sold_qty <= granted_qty) stays meaningful across renewals
		// without resetting sold_qty. It is computed from the sold_qty the allocator saw, not the current
		// one: units sold after the report are then taken out of the new grant instead of adding to it,
		// which is what keeps the sum of all cells' totals within stock. GREATEST keeps the CHECK true
		// when the cell has already sold past the new total (it simply has nothing left to sell).
		Optional<Lease> applied = this.jdbc.sql("""
				INSERT INTO inventory.inventory_lease AS l (sku, granted_qty, sold_qty, lease_epoch, expires_at)
				VALUES (:sku, :total, 0, :epoch, :exp)
				ON CONFLICT (sku) DO UPDATE
				   SET granted_qty = GREATEST(l.sold_qty, EXCLUDED.granted_qty),
				       lease_epoch = EXCLUDED.lease_epoch,
				       expires_at  = EXCLUDED.expires_at,
				       updated_at  = now()
				 WHERE l.lease_epoch < EXCLUDED.lease_epoch
				RETURNING lease_epoch, granted_qty""")
			.param("sku", g.sku())
			.param("total", g.reportedSold() + g.remainingQty())
			.param("epoch", g.epoch())
			.param("exp", g.expiresAt())
			.query((rs, n) -> new Lease(rs.getLong("lease_epoch"), rs.getInt("granted_qty")))
			.optional();
		// Empty only when a concurrent first grant for this SKU won the insert: that one holds a newer lease.
		return applied.map((lease) -> new Result(Outcome.APPLIED, null, lease.epoch(), lease.granted()))
			.orElseGet(() -> new Result(Outcome.STALE, null, current.epoch(), current.granted()));
	}

}
