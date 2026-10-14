package dev.cloudbridge.inventory;

import dev.cloudbridge.common.Problems;

import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.Optional;

@RestController
class InventoryController {

	private final InventoryCache cache;

	private final JdbcClient jdbc;

	InventoryController(InventoryCache cache, JdbcClient jdbc) {
		this.cache = cache;
		this.jdbc = jdbc;
	}

	@GetMapping("/inventory/{sku}")
	ResponseEntity<?> get(@PathVariable String sku) {
		Optional<Sellable> hit = this.cache.get(sku);
		if (hit.isPresent()) {
			return ResponseEntity.ok(hit.get());
		}
		Optional<Sellable> fromDb = load(sku);
		if (fromDb.isEmpty()) {
			return ResponseEntity.status(404)
				.contentType(MediaType.APPLICATION_PROBLEM_JSON)
				.body(Problems.NOT_FOUND.detail("no product " + sku));
		}
		this.cache.put(fromDb.get());
		return ResponseEntity.ok(fromDb.get());
	}

	/** I6. A product without a lease (or with an expired one) has nothing sellable in this cell. */
	private Optional<Sellable> load(String sku) {
		return this.jdbc.sql("""
				SELECT p.sku, p.name, p.price_paise,
				       greatest(coalesce(l.granted_qty - l.sold_qty, 0), 0) AS sellable,
				       coalesce(l.expires_at > now(), false)              AS lease_valid,
				       l.expires_at
				  FROM inventory.products p
				  LEFT JOIN inventory.inventory_lease l ON l.sku = p.sku
				 WHERE p.sku = :sku""")
			.param("sku", sku)
			.query((rs, n) -> {
				boolean valid = rs.getBoolean(5);
				return new Sellable(rs.getString(1), rs.getString(2), rs.getLong(3), valid ? rs.getInt(4) : 0, valid,
						rs.getObject(6, OffsetDateTime.class));
			})
			.optional();
	}

}
