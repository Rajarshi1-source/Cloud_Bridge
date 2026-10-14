package dev.cloudbridge.inventory;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.connection.stream.Consumer;
import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.ReadOffset;
import org.springframework.data.redis.connection.stream.StreamOffset;
import org.springframework.data.redis.connection.stream.StreamReadOptions;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Consumes order.created from the cell's Valkey stream and confirms the reservation (I2).
 * Delivery is at-least-once and confirm is idempotent, so duplicates are harmless. A record is
 * acknowledged only after it was handled; unacked records are re-read from this consumer's
 * pending list first on the next poll.
 */
@Component
public class OrderEventsConsumer {

	static final String STREAM = "stream:cell-events";

	static final String GROUP = "inventory-service";

	private static final Logger log = LoggerFactory.getLogger(OrderEventsConsumer.class);

	private final StringRedisTemplate valkey;

	private final ReservationService reservations;

	private final JsonMapper json;

	private final String consumerName;

	private volatile boolean groupReady;

	public OrderEventsConsumer(StringRedisTemplate valkey, ReservationService reservations, JsonMapper json,
			@Value("${HOSTNAME:inventory-local}") String consumerName) {
		this.valkey = valkey;
		this.reservations = reservations;
		this.json = json;
		this.consumerName = consumerName;
	}

	@Scheduled(fixedDelayString = "${cloudbridge.events.poll-ms:1000}")
	void scheduledPoll() {
		try {
			poll();
		}
		catch (RuntimeException ex) {
			log.warn("order event poll failed, will retry: {}", ex.toString());
		}
	}

	/** Handles one batch (pending first, then new); returns how many records were acknowledged. */
	public int poll() {
		ensureGroup();
		int handled = handle(read(ReadOffset.from("0"))); // our own unacked records first
		return handled + handle(read(ReadOffset.lastConsumed()));
	}

	private List<MapRecord<String, Object, Object>> read(ReadOffset offset) {
		List<MapRecord<String, Object, Object>> records = this.valkey.opsForStream()
			.read(Consumer.from(GROUP, this.consumerName), StreamReadOptions.empty().count(100),
					StreamOffset.create(STREAM, offset));
		return (records != null) ? records : List.of();
	}

	private int handle(List<MapRecord<String, Object, Object>> records) {
		int acked = 0;
		for (MapRecord<String, Object, Object> rec : records) {
			Map<Object, Object> fields = rec.getValue();
			if ("order.created".equals(fields.get("type"))) {
				Map<?, ?> payload = this.json.readValue(String.valueOf(fields.get("payload")), Map.class);
				this.reservations.confirm(UUID.fromString(String.valueOf(payload.get("reservation_id"))));
			}
			this.valkey.opsForStream().acknowledge(STREAM, GROUP, rec.getId());
			acked++;
		}
		return acked;
	}

	private void ensureGroup() {
		if (this.groupReady) {
			return;
		}
		try {
			byte[] key = STREAM.getBytes(StandardCharsets.UTF_8);
			this.valkey.execute((RedisCallback<String>) (c) -> c.streamCommands()
				.xGroupCreate(key, GROUP, ReadOffset.from("0"), true)); // MKSTREAM: works before the first event
		}
		catch (RuntimeException ex) {
			if (!String.valueOf(ex.getMessage()).contains("BUSYGROUP")) {
				throw ex;
			}
		}
		this.groupReady = true;
	}

}
