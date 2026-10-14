package dev.cloudbridge.order;

import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.BDDMockito.given;

/** The HTTP contract: status codes, problem types, Location, Idempotent-Replayed. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = "cloudbridge.cell=cb-test-cell")
class OrderApiIT {

	private static final HttpClient HTTP = HttpClient.newHttpClient();

	@Value("${local.server.port}")
	int port;

	@Autowired
	JsonMapper json;

	@MockitoBean
	InventoryClient inventory;

	HttpResponse<String> send(HttpRequest.Builder b) throws IOException, InterruptedException {
		return HTTP.send(b.build(), HttpResponse.BodyHandlers.ofString());
	}

	HttpRequest.Builder post(String key, String body) {
		HttpRequest.Builder b = HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + "/orders"))
			.header("Content-Type", "application/json")
			.POST(HttpRequest.BodyPublishers.ofString(body));
		return (key != null) ? b.header("Idempotency-Key", key) : b;
	}

	HttpRequest.Builder get(String path) {
		return HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + path));
	}

	static String body(UUID customer, String sku, int qty) {
		return """
				{"customerId":"%s","items":[{"sku":"%s","qty":%d,"pricePaise":49900}]}""".formatted(customer, sku, qty);
	}

	@Test
	void createReplayAndRead() throws Exception {
		given(this.inventory.reserve(any(), anyString(), anyInt())).willReturn(true);
		UUID customer = UUID.randomUUID();
		String key = UUID.randomUUID().toString();

		HttpResponse<String> created = send(post(key, body(customer, "SKU-1", 2)));
		assertThat(created.statusCode()).isEqualTo(201);
		JsonNode order = this.json.readTree(created.body());
		String id = order.get("orderId").stringValue();
		assertThat(created.headers().firstValue("Location")).hasValue("/orders/" + id);

		HttpResponse<String> replay = send(post(key, body(customer, "SKU-1", 2)));
		assertThat(replay.statusCode()).isEqualTo(201);
		assertThat(replay.headers().firstValue("Idempotent-Replayed")).hasValue("true");
		assertThat(this.json.readTree(replay.body())).isEqualTo(order);

		HttpResponse<String> read = send(get("/orders/" + id));
		assertThat(read.statusCode()).isEqualTo(200);
		JsonNode view = this.json.readTree(read.body());
		assertThat(view.get("totalPaise").asLong()).isEqualTo(99_800);
		assertThat(view.get("items").size()).isEqualTo(1);

		HttpResponse<String> list = send(get("/orders?customerId=" + customer));
		assertThat(this.json.readTree(list.body()).size()).isEqualTo(1);
	}

	@Test
	void problemsHaveStableTypes() throws Exception {
		HttpResponse<String> noKey = send(post(null, body(UUID.randomUUID(), "SKU-1", 1)));
		assertThat(noKey.statusCode()).isEqualTo(400);
		assertThat(noKey.body()).contains("/problems/missing-idempotency-key");

		HttpResponse<String> invalid = send(post(UUID.randomUUID().toString(), body(UUID.randomUUID(), "SKU-1", 0)));
		assertThat(invalid.statusCode()).isEqualTo(400);
		assertThat(invalid.headers().firstValue("Content-Type")).hasValueSatisfying((v) -> assertThat(v).contains("application/problem+json"));
		JsonNode problem = this.json.readTree(invalid.body());
		assertThat(problem.get("type").stringValue()).endsWith("/problems/validation-failed");
		assertThat(problem.get("errors").get(0).get("field").stringValue()).isEqualTo("items[0].qty");

		HttpResponse<String> dupSku = send(post(UUID.randomUUID().toString(), """
				{"customerId":"%s","items":[{"sku":"SKU-1","qty":1,"pricePaise":1},{"sku":"SKU-1","qty":1,"pricePaise":1}]}"""
			.formatted(UUID.randomUUID())));
		assertThat(dupSku.statusCode()).isEqualTo(400);

		given(this.inventory.reserve(any(), anyString(), anyInt())).willReturn(false);
		HttpResponse<String> soldOut = send(post(UUID.randomUUID().toString(), body(UUID.randomUUID(), "SKU-9", 1)));
		assertThat(soldOut.statusCode()).isEqualTo(409);
		assertThat(this.json.readTree(soldOut.body()).get("sku").stringValue()).isEqualTo("SKU-9");

		HttpResponse<String> missing = send(get("/orders/" + UUID.randomUUID()));
		assertThat(missing.statusCode()).isEqualTo(404);
		assertThat(missing.body()).contains("/problems/not-found");
	}

}
