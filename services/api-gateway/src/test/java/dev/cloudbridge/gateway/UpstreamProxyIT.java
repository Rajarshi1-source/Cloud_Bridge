package dev.cloudbridge.gateway;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetSocketAddress;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * What a healthy upstream actually receives through the gateway: the full POST body and the
 * Idempotency-Key header. A stub upstream echoes both back.
 */
@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class UpstreamProxyIT {

	static final HttpServer UPSTREAM = startUpstream();

	@Value("${local.server.port}")
	int port;

	static HttpServer startUpstream() {
		try {
			HttpServer server = HttpServer.create(new InetSocketAddress("localhost", 0), 0);
			server.createContext("/", (exchange) -> {
				byte[] body = exchange.getRequestBody().readAllBytes();
				String key = exchange.getRequestHeaders().getFirst("Idempotency-Key");
				byte[] out = ("{\"method\":\"%s\",\"bodyLength\":%d,\"key\":\"%s\"}"
					.formatted(exchange.getRequestMethod(), body.length, key)).getBytes(StandardCharsets.UTF_8);
				exchange.getResponseHeaders().add("Content-Type", "application/json");
				exchange.sendResponseHeaders(201, out.length);
				exchange.getResponseBody().write(out);
				exchange.close();
			});
			server.start();
			return server;
		}
		catch (IOException ex) {
			throw new UncheckedIOException(ex);
		}
	}

	@DynamicPropertySource
	static void upstream(DynamicPropertyRegistry registry) {
		String url = "http://localhost:" + UPSTREAM.getAddress().getPort();
		registry.add("cloudbridge.order-url", () -> url);
		registry.add("cloudbridge.inventory-url", () -> url);
	}

	@AfterAll
	static void stop() {
		UPSTREAM.stop(0);
	}

	@Test
	void postOrderReachesTheUpstreamWithBodyAndIdempotencyKey() {
		String key = UUID.randomUUID().toString();
		String body = """
				{"customerId":"%s","items":[{"sku":"SKU-1","qty":1,"pricePaise":49900}]}""".formatted(UUID.randomUUID());
		HttpResponse<String> res = Http.send(Http.at(this.port, "/orders")
			.header("Content-Type", "application/json")
			.header("Idempotency-Key", key)
			.POST(HttpRequest.BodyPublishers.ofString(body)));

		assertThat(res.statusCode()).isEqualTo(201);
		assertThat(res.body()).contains("\"bodyLength\":" + body.getBytes(StandardCharsets.UTF_8).length)
			.contains("\"key\":\"" + key + "\"");
	}

	@Test
	void getIsProxiedToo() {
		HttpResponse<String> res = Http.send(Http.at(this.port, "/inventory/SKU-1"));
		assertThat(res.statusCode()).isEqualTo(201);
		assertThat(res.body()).contains("\"method\":\"GET\"");
	}

}
