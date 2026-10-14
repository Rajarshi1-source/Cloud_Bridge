package dev.cloudbridge.order;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Housekeeping: key TTL, stuck keys, published outbox rows, stream length. */
@Component
class Sweeps {

	private static final Logger log = LoggerFactory.getLogger(Sweeps.class);

	private final JdbcClient jdbc;

	private final StringRedisTemplate valkey;

	Sweeps(JdbcClient jdbc, StringRedisTemplate valkey) {
		this.jdbc = jdbc;
		this.valkey = valkey;
	}

	@Scheduled(fixedDelayString = "${cloudbridge.sweeps.interval-ms:60000}")
	void sweep() {
		// O7: a PENDING key older than 2 min belongs to a crashed request; FAILED lets the client retry.
		int stuck = this.jdbc.sql("""
				UPDATE orders.idempotency_keys SET status = 'FAILED', updated_at = now()
				 WHERE status = 'PENDING' AND updated_at < now() - interval '2 minutes'""").update();
		// O6: keys are kept 24 h; published outbox rows 7 days.
		int keys = this.jdbc.sql("""
				DELETE FROM orders.idempotency_keys
				 WHERE created_at < now() - interval '24 hours' AND status <> 'PENDING'""").update();
		int outbox = this.jdbc.sql("DELETE FROM orders.outbox WHERE published_at < now() - interval '7 days'").update();
		if (stuck + keys + outbox > 0) {
			log.info("sweep: {} stuck keys failed, {} keys expired, {} outbox rows trimmed", stuck, keys, outbox);
		}
		try {
			this.valkey.opsForStream().trim(OutboxRelay.STREAM, 100_000, true); // XTRIM MAXLEN ~ 100000
		}
		catch (RuntimeException ex) {
			log.debug("stream trim skipped: {}", ex.toString());
		}
	}

}
