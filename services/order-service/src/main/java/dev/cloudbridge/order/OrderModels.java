package dev.cloudbridge.order;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class OrderModels {

	private OrderModels() {
	}

	public record Item(@NotBlank @Size(max = 64) String sku, @Min(1) @Max(100) int qty,
			@Min(0) @Max(100_000_000_00L) long pricePaise) {
	}

	public record CreateOrder(@NotNull UUID customerId, @NotEmpty @Size(max = 50) List<@Valid @NotNull Item> items) {

		/** Bounded by the validation limits above, so it can't overflow. */
		public long totalPaise() {
			return this.items.stream().mapToLong((i) -> i.pricePaise() * i.qty()).sum();
		}

		public boolean hasDuplicateSkus() {
			return this.items.stream().map(Item::sku).distinct().count() != this.items.size();
		}

	}

	/** The 201 body. Stored verbatim in idempotency_keys so a replay returns identical bytes. */
	public record OrderCreated(UUID orderId, String cell, String status, long totalPaise, String currency) {
	}

	public record OrderView(UUID id, String cell, UUID customerId, String status, long totalPaise, String currency,
			OffsetDateTime createdAt, List<ItemView> items) {
	}

	public record ItemView(String sku, int qty, long pricePaise) {
	}

	public record OrderSummary(UUID id, String status, long totalPaise, String currency, OffsetDateTime createdAt) {
	}

	/** Result of the claim → reserve → commit saga. */
	public sealed interface Outcome permits Created, Replayed, InProgress, Mismatch, OutOfStock, DependencyUnavailable {

	}

	public record Created(OrderCreated body, String json) implements Outcome {
	}

	public record Replayed(int status, String json) implements Outcome {
	}

	public record InProgress() implements Outcome {
	}

	public record Mismatch() implements Outcome {
	}

	public record OutOfStock(String sku) implements Outcome {
	}

	public record DependencyUnavailable(String dependency) implements Outcome {
	}

}
