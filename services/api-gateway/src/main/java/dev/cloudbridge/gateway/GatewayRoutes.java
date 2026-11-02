package dev.cloudbridge.gateway;

import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.circuitbreaker.resilience4j.Resilience4JCircuitBreakerFactory;
import org.springframework.cloud.circuitbreaker.resilience4j.Resilience4JConfigBuilder;
import org.springframework.cloud.client.circuitbreaker.Customizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.web.servlet.function.RequestPredicate;
import org.springframework.web.servlet.function.RouterFunction;
import org.springframework.web.servlet.function.ServerResponse;

import java.time.Duration;
import java.util.Set;

import static org.springframework.cloud.gateway.server.mvc.filter.BeforeFilterFunctions.uri;
import static org.springframework.cloud.gateway.server.mvc.filter.CircuitBreakerFilterFunctions.circuitBreaker;
import static org.springframework.cloud.gateway.server.mvc.filter.RetryFilterFunctions.retry;
import static org.springframework.cloud.gateway.server.mvc.handler.GatewayRouterFunctions.route;
import static org.springframework.cloud.gateway.server.mvc.handler.HandlerFunctions.http;
import static org.springframework.web.servlet.function.RequestPredicates.GET;
import static org.springframework.web.servlet.function.RequestPredicates.POST;

/**
 * Routes, in Java so the compiler checks them. Only routes listed here are reachable: internal
 * endpoints (POST /reservations, /admin/**) are never routed from the public host.
 * The gateway retries GETs only; clients retry POST /orders under the same Idempotency-Key
 * (IdempotencyKeyGuard rejects a POST without one before it gets here).
 */
@Configuration(proxyBeanMethods = false)
class GatewayRoutes {

	private static final String FALLBACK = "forward:/fallback/unavailable";

	@Bean
	RouterFunction<ServerResponse> orderRoutes(@Value("${cloudbridge.order-url}") String orderUrl) {
		return route("orders")
			.route(POST("/orders").or(GET("/orders")).or(GET("/orders/{id}")), http())
			.before(uri(orderUrl))
			.filter(circuitBreaker((c) -> c.setId("orders").setFallbackUri(FALLBACK).setStatusCodes("500", "502", "503", "504")))
			// GETs only. Retrying POST needs the filter's body caching, which forwarded an EMPTY body
			// upstream (UpstreamProxyIT). POST /orders is retried by the client instead: it holds the
			// Idempotency-Key, and a 503 from the fallback carries Retry-After.
			.filter(retry((c) -> c.setRetries(2)
				.setMethods(Set.of(HttpMethod.GET))
				.setSeries(Set.of(HttpStatus.Series.SERVER_ERROR))
				.setBackoff(Duration.ofMillis(50), Duration.ofMillis(400), 2)))
			.build();
	}

	@Bean
	RouterFunction<ServerResponse> inventoryRoutes(@Value("${cloudbridge.inventory-url}") String inventoryUrl) {
		return route("inventory")
			.route(GET("/inventory/{sku}"), http())
			.before(uri(inventoryUrl))
			.filter(circuitBreaker((c) -> c.setId("inventory").setFallbackUri(FALLBACK).setStatusCodes("500", "502", "503", "504")))
			.filter(retry((c) -> c.setRetries(2)
				.setMethods(Set.of(HttpMethod.GET))
				.setSeries(Set.of(HttpStatus.Series.SERVER_ERROR))
				.setBackoff(Duration.ofMillis(50), Duration.ofMillis(400), 2)))
			.build();
	}

	/**
	 * Admin host only. Cf-Access-Jwt-Assertion is forwarded unchanged because inventory-service
	 * validates it again. No breaker or retry: the allocator retries on its next cycle.
	 */
	@Bean
	RouterFunction<ServerResponse> adminRoutes(@Value("${cloudbridge.inventory-url}") String inventoryUrl,
			@Value("${cloudbridge.admin.host}") String adminHost) {
		// The hostname alone, as SecurityConfig compares it; the gateway's host() predicate compares the whole Host header, port included.
		RequestPredicate onAdminHost = (request) -> adminHost.equalsIgnoreCase(request.servletRequest().getServerName());
		return route("admin-leases")
			.route(onAdminHost.and(POST("/admin/leases/grant").or(GET("/admin/leases/report"))), http())
			.before(uri(inventoryUrl))
			.build();
	}

	/** Every breaker (orders, inventory, valkey): 50% failures over 20 calls → open 30 s → 5 trial calls. */
	@Bean
	Customizer<Resilience4JCircuitBreakerFactory> breakerDefaults() {
		return (factory) -> factory.configureDefault((id) -> new Resilience4JConfigBuilder(id)
			.circuitBreakerConfig(CircuitBreakerConfig.custom()
				.slidingWindowSize(20)
				.minimumNumberOfCalls(20)
				.failureRateThreshold(50)
				.waitDurationInOpenState(Duration.ofSeconds(30))
				.permittedNumberOfCallsInHalfOpenState(5)
				.build())
			.build());
	}

}
