package dev.cloudbridge.order;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.data.redis.connection.stream.MapRecord;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Relays outbox rows to the Valkey stream. At-least-once: a row is marked published only in the
 * same transaction that read it, after XADD succeeded; if Valkey is down XADD throws, the
 * transaction rolls back and the rows are retried. Consumers dedupe on the event id.
 * {@code FOR UPDATE SKIP LOCKED} lets several replicas relay concurrently without double work.
 */
@Component
public class OutboxRelay {

	public static final String STREAM = "stream:cell-events";

	private static final Logger log = LoggerFactory.getLogger(OutboxRelay.class);

	private final JdbcClient jdbc;

	private final StringRedisTemplate valkey;

	private final TransactionTemplate tx;

	public OutboxRelay(JdbcClient jdbc, StringRedisTemplate valkey, TransactionTemplate tx) {
		this.jdbc = jdbc;
		this.valkey = valkey;
		this.tx = tx;
	}

	@Scheduled(fixedDelayString = "${cloudbridge.outbox.poll-ms:500}")
	void scheduledRelay() {
		try {
			relay();
		}
		catch (RuntimeException ex) {
			log.warn("outbox relay failed, rows stay unpublished and will be retried: {}", ex.toString());
		}
	}

	/** Publishes one batch; returns how many events were published. */
	public int relay() {
		Integer published = this.tx.execute((status) -> {
			List<Row> rows = this.jdbc.sql("""
					SELECT id, event_type, payload::text FROM orders.outbox
					 WHERE published_at IS NULL
					 ORDER BY created_at
					 LIMIT 100
					   FOR UPDATE SKIP LOCKED""")
				.query((rs, n) -> new Row(rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3)))
				.list();
			for (Row r : rows) {
				MapRecord<String, String, String> rec = StreamRecords.newRecord()
					.in(STREAM)
					.ofMap(Map.of("id", r.id().toString(), "type", r.type(), "payload", r.payload()));
				this.valkey.opsForStream().add(rec);
				this.jdbc.sql("UPDATE orders.outbox SET published_at = now(), attempts = attempts + 1 WHERE id = :id")
					.param("id", r.id())
					.update();
			}
			return rows.size();
		});
		return (published != null) ? published : 0;
	}

	private record Row(UUID id, String type, String payload) {
	}

}
