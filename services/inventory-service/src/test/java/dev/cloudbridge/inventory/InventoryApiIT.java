package dev.cloudbridge.inventory;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.assertj.core.api.Assertions.assertThat;

@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class InventoryApiIT {

	private static final HttpClient HTTP = HttpClient.newHttpClient();

	@Value("${local.server.port}")
	int port;

	@Autowired
	JdbcClient jdbc;

	String sku;

	@BeforeEach
	void freshSku() {
		this.sku = "SKU-" + UUID.randomUUID();
		this.jdbc.sql("INSERT INTO inventory.products (sku, name, price_paise) VALUES (:s, 'Widget', 49900)")
			.param("s", this.sku)
			.update();
		this.jdbc.sql("""
				INSERT INTO inventory.inventory_lease (sku, granted_qty, lease_epoch, expires_at)
				VALUES (:s, 5, 1, now() + interval '15 minutes')""").param("s", this.sku).update();
	}

	HttpResponse<String> reserve(UUID rid, int qty) {
		try {
			return HTTP.send(HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + "/reservations"))
				.header("Content-Type", "application/json")
				.POST(HttpRequest.BodyPublishers.ofString(
						"{\"reservationId\":\"%s\",\"sku\":\"%s\",\"qty\":%d}".formatted(rid, this.sku, qty)))
				.build(), HttpResponse.BodyHandlers.ofString());
		}
		catch (Exception ex) {
			throw new IllegalStateException(ex);
		}
	}

	@Test
	void reserveStatusCodes() {
		UUID rid = UUID.randomUUID();
		assertThat(reserve(rid, 2).statusCode()).isEqualTo(201);
		assertThat(reserve(rid, 2).statusCode()).isEqualTo(200);
		HttpResponse<String> soldOut = reserve(UUID.randomUUID(), 4);
		assertThat(soldOut.statusCode()).isEqualTo(409);
		assertThat(soldOut.body()).contains("/problems/out-of-stock-in-cell");
	}

	@Test
	void concurrentDuplicatesOfOneReservationSellOnce() throws Exception {
		UUID rid = UUID.randomUUID();
		List<Future<Integer>> codes = new ArrayList<>();
		try (ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {
			for (int i = 0; i < 10; i++) {
				codes.add(pool.submit(() -> reserve(rid, 2).statusCode()));
			}
		}
		List<Integer> statuses = new ArrayList<>();
		for (Future<Integer> f : codes) {
			statuses.add(f.get());
		}
		assertThat(statuses).containsOnly(200, 201);
		assertThat(statuses).filteredOn((s) -> s == 201).hasSize(1);
		assertThat(this.jdbc.sql("SELECT sold_qty FROM inventory.inventory_lease WHERE sku = :s")
			.param("s", this.sku)
			.query(Integer.class)
			.single()).isEqualTo(2);
	}

	@Test
	void readModelShowsWhatThisCellCanSell() throws Exception {
		reserve(UUID.randomUUID(), 2);
		HttpResponse<String> res = HTTP.send(
				HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + "/inventory/" + this.sku)).build(),
				HttpResponse.BodyHandlers.ofString());
		assertThat(res.statusCode()).isEqualTo(200);
		assertThat(res.body()).contains("\"sellableInCell\":3").contains("\"leaseValid\":true");

		HttpResponse<String> missing = HTTP.send(
				HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + "/inventory/NOPE")).build(),
				HttpResponse.BodyHandlers.ofString());
		assertThat(missing.statusCode()).isEqualTo(404);
	}

}
