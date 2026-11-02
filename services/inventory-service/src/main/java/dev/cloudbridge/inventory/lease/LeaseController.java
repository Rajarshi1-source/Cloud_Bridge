package dev.cloudbridge.inventory.lease;

import dev.cloudbridge.common.Problems;
import dev.cloudbridge.inventory.lease.LeaseGrantService.Grant;
import dev.cloudbridge.inventory.lease.LeaseGrantService.Result;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;

/** Auth is enforced by the admin SecurityFilterChain (Access JWT + ROLE_LEASE_ALLOCATOR) in the gateway AND here. */
@RestController
@RequestMapping("/admin/leases")
class LeaseController {

	record GrantRequest(@NotBlank String sku, @Min(0) int remainingQty, @Min(0) int reportedSold, @Min(1) long epoch,
			@NotNull OffsetDateTime expiresAt) {
	}

	record LeaseReport(String sku, int grantedQty, int soldQty, long leaseEpoch, OffsetDateTime expiresAt) {
	}

	private final LeaseGrantService grants;

	private final JdbcClient jdbc;

	LeaseController(LeaseGrantService grants, JdbcClient jdbc) {
		this.grants = grants;
		this.jdbc = jdbc;
	}

	@PostMapping("/grant")
	ResponseEntity<?> grant(@Valid @RequestBody GrantRequest req, JwtAuthenticationToken auth) {
		Result r = this.grants.apply(
				new Grant(req.sku(), req.remainingQty(), req.reportedSold(), req.epoch(), req.expiresAt()),
				auth.getName(), auth.getToken().getId());
		return switch (r.outcome()) {
			case APPLIED -> ResponseEntity.ok(Map.of("epoch", r.epoch(), "grantedQty", r.grantedQty(), "replayed", false));
			case REPLAYED -> ResponseEntity.ok(Map.of("epoch", r.epoch(), "grantedQty", r.grantedQty(), "replayed", true));
			case STALE, EPOCH_REUSED -> problem(Problems.STALE_LEASE_EPOCH,
					"current epoch " + r.epoch() + ", received " + req.epoch(), null);
			case OUT_OF_BOUNDS -> problem(Problems.LEASE_GRANT_OUT_OF_BOUNDS, "rule: " + r.rule(), r.rule());
			case UNKNOWN_SKU -> problem(Problems.LEASE_GRANT_OUT_OF_BOUNDS, "unknown sku " + req.sku(), "sku");
		};
	}

	@GetMapping("/report")
	List<LeaseReport> report() {
		return this.jdbc.sql("SELECT sku, granted_qty, sold_qty, lease_epoch, expires_at FROM inventory.inventory_lease")
			.query((rs, n) -> new LeaseReport(rs.getString("sku"), rs.getInt("granted_qty"), rs.getInt("sold_qty"),
					rs.getLong("lease_epoch"), rs.getObject("expires_at", OffsetDateTime.class)))
			.list();
	}

	private static ResponseEntity<ProblemDetail> problem(Problems p, String detail, String rule) {
		ProblemDetail pd = p.detail(detail);
		if (rule != null) {
			pd.setProperty("rule", rule);
		}
		return ResponseEntity.status(p.status).contentType(MediaType.APPLICATION_PROBLEM_JSON).body(pd);
	}

}
