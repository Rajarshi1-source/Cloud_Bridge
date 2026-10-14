package dev.cloudbridge.inventory;

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.Optional;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Cache-aside for the inventory read model ({@code inv:{sku}}, 30 s + jitter). Behind the
 * {@code valkey} breaker: when Valkey is down the fallbacks turn every call into a miss / no-op,
 * so reads go to Postgres and the cell only gets slower.
 */
@Component
public class InventoryCache {

	private final StringRedisTemplate valkey;

	private final JsonMapper json;

	public InventoryCache(StringRedisTemplate valkey, JsonMapper json) {
		this.valkey = valkey;
		this.json = json;
	}

	@CircuitBreaker(name = "valkey", fallbackMethod = "miss")
	public Optional<Sellable> get(String sku) {
		String cached = this.valkey.opsForValue().get(key(sku));
		return Optional.ofNullable(cached).map((s) -> this.json.readValue(s, Sellable.class));
	}

	@CircuitBreaker(name = "valkey", fallbackMethod = "skip")
	public void put(Sellable value) {
		Duration ttl = Duration.ofSeconds(30).plusMillis(ThreadLocalRandom.current().nextLong(5_000)); // jitter
		this.valkey.opsForValue().set(key(value.sku()), this.json.writeValueAsString(value), ttl);
	}

	public Optional<Sellable> miss(String sku, Throwable cause) {
		return Optional.empty();
	}

	public void skip(Sellable value, Throwable cause) {
	}

	private static String key(String sku) {
		return "inv:" + sku;
	}

}
