package dev.cloudbridge.inventory;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.annotation.DirtiesContext;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import static org.assertj.core.api.Assertions.assertThat;

/** A dead cache costs latency, not availability: reads fall back to Postgres. Owns its containers. */
@Testcontainers
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@DirtiesContext
class CacheDownIT {

	@Container
	@ServiceConnection
	static PostgreSQLContainer postgres = new PostgreSQLContainer("postgres:18.4-alpine");

	@Container
	@ServiceConnection(name = "redis")
	static GenericContainer<?> valkey = new GenericContainer<>("valkey/valkey:9.0-alpine").withExposedPorts(6379);

	@Value("${local.server.port}")
	int port;

	@Autowired
	JdbcClient jdbc;

	@Test
	void inventoryReadsSurviveValkeyOutage() throws Exception {
		this.jdbc.sql("INSERT INTO inventory.products (sku, name, price_paise) VALUES ('SKU-C', 'Widget', 1)").update();
		valkey.stop();

		HttpResponse<String> res = HttpClient.newHttpClient()
			.send(HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + "/inventory/SKU-C")).build(),
					HttpResponse.BodyHandlers.ofString());
		assertThat(res.statusCode()).isEqualTo(200);
		assertThat(res.body()).contains("\"sku\":\"SKU-C\"").contains("\"sellableInCell\":0");
	}

}
