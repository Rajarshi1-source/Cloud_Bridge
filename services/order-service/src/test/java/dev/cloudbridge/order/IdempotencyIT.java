package dev.cloudbridge.order;

import dev.cloudbridge.order.OrderModels.CreateOrder;
import dev.cloudbridge.order.OrderModels.Created;
import dev.cloudbridge.order.OrderModels.DependencyUnavailable;
import dev.cloudbridge.order.OrderModels.Item;
import dev.cloudbridge.order.OrderModels.Mismatch;
import dev.cloudbridge.order.OrderModels.OutOfStock;
import dev.cloudbridge.order.OrderModels.Replayed;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.web.client.ResourceAccessException;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.verify;

@Import(TestcontainersConfiguration.class)
@SpringBootTest(properties = "cloudbridge.cell=cb-test-cell")
class IdempotencyIT {

	@Autowired
	IdempotentOrderService service;

	@Autowired
	JdbcClient jdbc;

	@Autowired
	JsonMapper json;

	@MockitoBean
	InventoryClient inventory;

	static CreateOrder order(String sku, int qty) {
		return new CreateOrder(UUID.randomUUID(), List.of(new Item(sku, qty, 49_900)));
	}

	String keyStatus(UUID key) {
		return this.jdbc.sql("SELECT status FROM orders.idempotency_keys WHERE key = :k")
			.param("k", key)
			.query(String.class)
			.single();
	}

	@Test
	void sameKeySameBodyCreatesOneOrderAndReplaysTheSameResponse() {
		given(this.inventory.reserve(any(), anyString(), anyInt())).willReturn(true);
		UUID key = UUID.randomUUID();
		CreateOrder req = order("SKU-1", 2);

		Created first = (Created) this.service.create(key, req);
		Replayed again = (Replayed) this.service.create(key, req);

		assertThat(again.status()).isEqualTo(201);
		assertThat(this.json.readTree(again.json())).isEqualTo(this.json.readTree(first.json()));
		assertThat(first.body().totalPaise()).isEqualTo(99_800);
		assertThat(first.body().cell()).isEqualTo("cb-test-cell");
		assertThat(first.body().orderId().version()).as("ids come from Postgres uuidv7()").isEqualTo(7);
		assertThat(this.jdbc.sql("SELECT count(*) FROM orders.orders WHERE reservation_id = :k")
			.param("k", key)
			.query(Integer.class)
			.single()).isEqualTo(1);
		assertThat(this.jdbc.sql("SELECT count(*) FROM orders.outbox WHERE aggregate_id = :o AND event_type = 'order.created'")
			.param("o", first.body().orderId())
			.query(Integer.class)
			.single()).isEqualTo(1);
		verify(this.inventory).confirm(key);
	}

	@Test
	void sameKeyDifferentBodyIsRejected() {
		given(this.inventory.reserve(any(), anyString(), anyInt())).willReturn(true);
		UUID key = UUID.randomUUID();
		this.service.create(key, order("SKU-1", 1));
		assertThat(this.service.create(key, order("SKU-1", 2))).isInstanceOf(Mismatch.class);
	}

	@Test
	void outOfStockReleasesHeldLinesAndTheSameKeyCanBeRetried() {
		UUID key = UUID.randomUUID();
		CreateOrder req = new CreateOrder(UUID.randomUUID(),
				List.of(new Item("SKU-1", 1, 49_900), new Item("SKU-2", 1, 129_900)));
		given(this.inventory.reserve(eq(key), eq("SKU-1"), anyInt())).willReturn(true);
		given(this.inventory.reserve(eq(key), eq("SKU-2"), anyInt())).willReturn(false);

		assertThat(this.service.create(key, req)).isEqualTo(new OutOfStock("SKU-2"));
		verify(this.inventory).release(key);
		assertThat(keyStatus(key)).isEqualTo("FAILED");

		given(this.inventory.reserve(eq(key), eq("SKU-2"), anyInt())).willReturn(true); // stock arrived
		assertThat(this.service.create(key, req)).isInstanceOf(Created.class);
		assertThat(keyStatus(key)).isEqualTo("COMPLETED");
	}

	@Test
	void inventoryOutageFailsTheKeySoTheClientCanRetry() {
		given(this.inventory.reserve(any(), anyString(), anyInt())).willThrow(new ResourceAccessException("timeout"));
		UUID key = UUID.randomUUID();
		assertThat(this.service.create(key, order("SKU-1", 1))).isInstanceOf(DependencyUnavailable.class);
		assertThat(keyStatus(key)).isEqualTo("FAILED");
	}

}
