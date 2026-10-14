package dev.cloudbridge.order;

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;

/**
 * Calls inventory-service in the SAME cell (never cross-cloud). Every call is idempotent on the
 * reservation id, so retries and duplicate deliveries are safe.
 */
@Component
public class InventoryClient {

	private final RestClient http;

	public InventoryClient(@Value("${cloudbridge.inventory-url}") String baseUrl) {
		SimpleClientHttpRequestFactory rf = new SimpleClientHttpRequestFactory();
		rf.setConnectTimeout(Duration.ofMillis(800));
		rf.setReadTimeout(Duration.ofMillis(1500));
		this.http = RestClient.builder().baseUrl(baseUrl).requestFactory(rf).build();
	}

	/** True if reserved (or already reserved under this id); false if out of stock in this cell. */
	@CircuitBreaker(name = "inventory")
	public boolean reserve(UUID reservationId, String sku, int qty) {
		try {
			this.http.post()
				.uri("/reservations")
				.body(Map.of("reservationId", reservationId, "sku", sku, "qty", qty))
				.retrieve()
				.toBodilessEntity();
			return true;
		}
		catch (HttpClientErrorException ex) {
			if (ex.getStatusCode() == HttpStatus.CONFLICT) {
				return false;
			}
			throw ex;
		}
	}

	/** Compensation: give back every HELD line of this reservation. */
	@CircuitBreaker(name = "inventory")
	public void release(UUID reservationId) {
		this.http.post().uri("/reservations/{id}/release", reservationId).retrieve().toBodilessEntity();
	}

	/** Fast-path confirmation right after commit; the order.created event is the durable path. */
	@CircuitBreaker(name = "inventory")
	public void confirm(UUID reservationId) {
		this.http.post().uri("/reservations/{id}/confirm", reservationId).retrieve().toBodilessEntity();
	}

}
