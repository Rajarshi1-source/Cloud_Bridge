package dev.cloudbridge.order;

import dev.cloudbridge.order.OrderModels.Created;
import io.lettuce.core.ClientOptions;
import io.lettuce.core.SocketOptions;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.data.domain.Range;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceClientConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.BDDMockito.given;

/** At-least-once: an event is marked published only after XADD succeeded, never before. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest(properties = "cloudbridge.cell=cb-test-cell")
class OutboxRelayIT {

	@Autowired
	IdempotentOrderService service;

	@Autowired
	OutboxRelay relay;

	@Autowired
	JdbcClient jdbc;

	@Autowired
	StringRedisTemplate valkey;

	@Autowired
	TransactionTemplate tx;

	@MockitoBean
	InventoryClient inventory;

	UUID newOrder() {
		given(this.inventory.reserve(any(), anyString(), anyInt())).willReturn(true);
		return ((Created) this.service.create(UUID.randomUUID(), IdempotencyIT.order("SKU-1", 1))).body().orderId();
	}

	boolean published(UUID orderId) {
		return this.jdbc.sql("SELECT published_at IS NOT NULL FROM orders.outbox WHERE aggregate_id = :o")
			.param("o", orderId)
			.query(Boolean.class)
			.single();
	}

	long eventsFor(UUID orderId) {
		return this.valkey.opsForStream()
			.range(OutboxRelay.STREAM, Range.unbounded())
			.stream()
			.filter((r) -> String.valueOf(r.getValue().get("payload")).contains(orderId.toString()))
			.count();
	}

	@Test
	void publishesOnceAndMarksTheRow() {
		UUID orderId = newOrder();
		assertThat(this.relay.relay()).isGreaterThanOrEqualTo(1);
		assertThat(published(orderId)).isTrue();
		assertThat(eventsFor(orderId)).isEqualTo(1);

		this.relay.relay(); // nothing left for this order: no duplicate
		assertThat(eventsFor(orderId)).isEqualTo(1);
	}

	@Test
	void valkeyDownLeavesTheEventUnpublishedForTheNextRun() {
		UUID orderId = newOrder();
		LettuceConnectionFactory dead = new LettuceConnectionFactory(new RedisStandaloneConfiguration("localhost", 1),
				LettuceClientConfiguration.builder()
					.commandTimeout(Duration.ofMillis(300))
					.clientOptions(ClientOptions.builder()
						.socketOptions(SocketOptions.builder().connectTimeout(Duration.ofMillis(300)).build())
						.build())
					.build());
		dead.afterPropertiesSet();
		dead.start();
		try {
			OutboxRelay relayWithDeadValkey = new OutboxRelay(this.jdbc, new StringRedisTemplate(dead), this.tx);
			assertThatThrownBy(relayWithDeadValkey::relay).isInstanceOf(RuntimeException.class);
			assertThat(published(orderId)).as("rolled back, so still pending").isFalse();
		}
		finally {
			dead.destroy();
		}

		this.relay.relay(); // Valkey is back
		assertThat(published(orderId)).isTrue();
		assertThat(eventsFor(orderId)).isEqualTo(1);
	}

}
