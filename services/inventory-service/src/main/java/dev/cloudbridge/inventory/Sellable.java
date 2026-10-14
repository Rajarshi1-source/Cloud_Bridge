package dev.cloudbridge.inventory;

import java.time.OffsetDateTime;

/** Read model: what this cell can still sell under its lease. Not the global stock level. */
public record Sellable(String sku, String name, long pricePaise, int sellableInCell, boolean leaseValid,
		OffsetDateTime leaseExpiresAt) {
}
