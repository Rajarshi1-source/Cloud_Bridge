package dev.cloudbridge.gateway;

import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;

import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The public API contract at the edge: Idempotency-Key guard, hidden admin paths, rate limiting
 * with RateLimit-* headers, breaker fallback as a retryable 503, and CORS for the dashboard only.
 * Upstreams point at a closed port, so every routed call exercises retry + breaker + fallback.
 */
@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
		properties = { "cloudbridge.cell=cb-test-cell", "cloudbridge.order-url=http://localhost:1",
				"cloudbridge.inventory-url=http://localhost:1", "cloudbridge.rate-limit.order-post-per-minute=2",
				"cloudbridge.cors.allowed-origins=https://cp.test" })
class EdgeContractIT {

	@Value("${local.server.port}")
	int port;

	private HttpRequest.Builder postOrder(String key, String clientIp) {
		HttpRequest.Builder b = Http.at(this.port, "/orders")
			.header("Content-Type", "application/json")
			.header("CF-Connecting-IP", clientIp)
			.POST(HttpRequest.BodyPublishers.ofString("""
					{"customerId":"%s","items":[{"sku":"SKU-1","qty":1,"pricePaise":49900}]}"""
				.formatted(UUID.randomUUID())));
		return (key != null) ? b.header("Idempotency-Key", key) : b;
	}

	@Test
	void postOrderWithoutIdempotencyKeyIsRejectedAtTheEdge() {
		HttpResponse<String> res = Http.send(postOrder(null, "198.51.100.1"));
		assertThat(res.statusCode()).isEqualTo(400);
		assertThat(res.headers().firstValue("Content-Type")).hasValueSatisfying((v) -> assertThat(v).contains("application/problem+json"));
		assertThat(res.body()).contains("/problems/missing-idempotency-key");
		assertThat(res.headers().firstValue("X-CB-Cell")).hasValue("cb-test-cell");
	}

	@Test
	void adminPathsDoNotExistOnThePublicHost() {
		HttpResponse<String> res = Http.send(Http.at(this.port, "/admin/leases/grant")
			.header("Content-Type", "application/json")
			.POST(HttpRequest.BodyPublishers.ofString("{}")));
		assertThat(res.statusCode()).isEqualTo(404);
		assertThat(Http.send(Http.at(this.port, "/reservations").POST(HttpRequest.BodyPublishers.noBody())).statusCode())
			.isEqualTo(404);
	}

	@Test
	void aPostToAnUnlistedRouteIsRefusedWithoutASession() {
		for (String path : new String[] { "/not-a-route", "/admin/leases/grant" }) {
			HttpResponse<String> res = Http.send(Http.at(this.port, path).POST(HttpRequest.BodyPublishers.noBody()));
			assertThat(res.statusCode()).isEqualTo(404);
			assertThat(res.headers().firstValue("Set-Cookie")).isEmpty();
		}
	}

	@Test
	void unreachableUpstreamBecomesARetryable503ThenRateLimitKicksIn() {
		String ip = "203.0.113.7";
		for (int i = 0; i < 2; i++) {
			HttpResponse<String> res = Http.send(postOrder(UUID.randomUUID().toString(), ip));
			assertThat(res.statusCode()).isEqualTo(503);
			assertThat(res.body()).contains("/problems/dependency-unavailable");
			assertThat(res.headers().firstValue("Retry-After")).isPresent();
			assertThat(res.headers().firstValue("RateLimit-Limit")).hasValue("2");
		}
		HttpResponse<String> limited = Http.send(postOrder(UUID.randomUUID().toString(), ip));
		assertThat(limited.statusCode()).isEqualTo(429);
		assertThat(limited.body()).contains("/problems/rate-limited");
		assertThat(limited.headers().firstValue("RateLimit-Remaining")).hasValue("0");
		assertThat(limited.headers().firstValue("Retry-After")).isPresent();

		// A different client is not affected.
		assertThat(Http.send(postOrder(UUID.randomUUID().toString(), "203.0.113.8")).statusCode()).isEqualTo(503);
	}

	@Test
	void corsAllowsOnlyTheDashboardOrigin() {
		HttpResponse<String> allowed = Http.send(Http.at(this.port, "/orders")
			.header("Origin", "https://cp.test")
			.header("Access-Control-Request-Method", "POST")
			.header("Access-Control-Request-Headers", "content-type,idempotency-key")
			.method("OPTIONS", HttpRequest.BodyPublishers.noBody()));
		assertThat(allowed.statusCode()).isEqualTo(200);
		assertThat(allowed.headers().firstValue("Access-Control-Allow-Origin")).hasValue("https://cp.test");

		HttpResponse<String> denied = Http.send(Http.at(this.port, "/orders")
			.header("Origin", "https://evil.example")
			.header("Access-Control-Request-Method", "POST")
			.method("OPTIONS", HttpRequest.BodyPublishers.noBody()));
		assertThat(denied.statusCode()).isEqualTo(403);
		assertThat(denied.headers().firstValue("Access-Control-Allow-Origin")).isEmpty();
	}

}
