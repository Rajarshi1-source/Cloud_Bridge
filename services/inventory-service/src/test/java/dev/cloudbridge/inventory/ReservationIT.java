package dev.cloudbridge.inventory;

import dev.cloudbridge.inventory.ReservationService.Result;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.data.redis.connection.stream.StreamRecords;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.assertj.core.api.Assertions.assertThat;

/** The escrow properties that make "never oversell" true inside a cell. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest
class ReservationIT {

	@Autowired
	ReservationService reservations;

	@Autowired
	OrderEventsConsumer consumer;

	@Autowired
	JdbcClient jdbc;

	@Autowired
	StringRedisTemplate valkey;

	String sku;

	@BeforeEach
	void freshSku() {
		this.sku = "SKU-" + UUID.randomUUID();
		this.jdbc.sql("INSERT INTO inventory.products (sku, name, price_paise) VALUES (:s, 'Widget', 49900)")
			.param("s", this.sku)
			.update();
		lease(20, "now() + interval '15 minutes'");
	}

	void lease(int granted, String expiresAtSql) {
		this.jdbc.sql("""
				INSERT INTO inventory.inventory_lease (sku, granted_qty, lease_epoch, expires_at)
				VALUES (:s, :g, 1, %s)
				ON CONFLICT (sku) DO UPDATE SET granted_qty = EXCLUDED.granted_qty, expires_at = EXCLUDED.expires_at"""
			.formatted(expiresAtSql)).param("s", this.sku).param("g", granted).update();
	}

	int sold() {
		return this.jdbc.sql("SELECT sold_qty FROM inventory.inventory_lease WHERE sku = :s")
			.param("s", this.sku)
			.query(Integer.class)
			.single();
	}

	String status(UUID rid) {
		return this.jdbc.sql("SELECT status FROM inventory.reservations WHERE reservation_id = :r AND sku = :s")
			.param("r", rid)
			.param("s", this.sku)
			.query(String.class)
			.single();
	}

	@Test
	void fiftyConcurrentBuyersAgainstALeaseOfTwentySellExactlyTwenty() throws Exception {
		List<Future<Result>> results = new ArrayList<>();
		try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
			for (int i = 0; i < 50; i++) {
				results.add(pool.submit(() -> this.reservations.reserve(UUID.randomUUID(), this.sku, 1)));
			}
		}
		long created = 0;
		for (Future<Result> f : results) {
			if (f.get() == Result.CREATED) {
				created++;
			}
		}
		assertThat(created).isEqualTo(20);
		assertThat(sold()).isEqualTo(20);
	}

	@Test
	void replayDoesNotSellTwice() {
		UUID rid = UUID.randomUUID();
		assertThat(this.reservations.reserve(rid, this.sku, 3)).isEqualTo(Result.CREATED);
		assertThat(this.reservations.reserve(rid, this.sku, 3)).isEqualTo(Result.REPLAYED);
		assertThat(sold()).isEqualTo(3);
	}

	@Test
	void expiredLeaseStopsSellingByItself() {
		lease(20, "now() - interval '1 second'");
		assertThat(this.reservations.reserve(UUID.randomUUID(), this.sku, 1)).isEqualTo(Result.OUT_OF_STOCK);
		assertThat(sold()).isZero();
	}

	@Test
	void releaseReturnsStockAndTheSameIdCanReserveAgain() {
		UUID rid = UUID.randomUUID();
		this.reservations.reserve(rid, this.sku, 5);
		assertThat(this.reservations.release(rid)).isEqualTo(1);
		assertThat(sold()).isZero();
		assertThat(this.reservations.release(rid)).as("idempotent").isZero();

		assertThat(this.reservations.reserve(rid, this.sku, 5)).isEqualTo(Result.CREATED);
		assertThat(sold()).isEqualTo(5);
	}

	@Test
	void reaperReleasesAbandonedHoldsButNotConfirmedOnes() {
		UUID abandoned = UUID.randomUUID();
		UUID confirmed = UUID.randomUUID();
		this.reservations.reserve(abandoned, this.sku, 2);
		this.reservations.reserve(confirmed, this.sku, 3);
		this.reservations.confirm(confirmed);
		this.jdbc.sql("UPDATE inventory.reservations SET created_at = now() - interval '20 minutes' WHERE sku = :s")
			.param("s", this.sku)
			.update();

		this.reservations.releaseExpired(15);

		assertThat(status(abandoned)).isEqualTo("RELEASED");
		assertThat(status(confirmed)).isEqualTo("CONFIRMED");
		assertThat(sold()).isEqualTo(3);
	}

	@Test
	void orderCreatedEventConfirmsTheReservationOnce() {
		UUID rid = UUID.randomUUID();
		this.reservations.reserve(rid, this.sku, 1);
		this.valkey.opsForStream()
			.add(StreamRecords.newRecord()
				.in(OrderEventsConsumer.STREAM)
				.ofMap(Map.of("id", UUID.randomUUID().toString(), "type", "order.created", "payload",
						"{\"reservation_id\":\"" + rid + "\",\"order_id\":\"" + UUID.randomUUID() + "\"}")));

		assertThat(this.consumer.poll()).isGreaterThanOrEqualTo(1);
		assertThat(status(rid)).isEqualTo("CONFIRMED");
		assertThat(this.consumer.poll()).as("acknowledged, not redelivered").isZero();
	}

}
