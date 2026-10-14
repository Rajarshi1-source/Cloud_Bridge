package dev.cloudbridge.gateway.web;

import dev.cloudbridge.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.client.circuitbreaker.CircuitBreaker;
import org.springframework.cloud.client.circuitbreaker.CircuitBreakerFactory;
import org.springframework.core.annotation.Order;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Fixed 60 s window per client and route class, counted in Valkey ({@code rl:{client}:{r|w}:{window}}).
 * Fails OPEN to per-pod counters when Valkey is down: a cache outage must not become an API outage.
 */
@Component
@Order(20)
class RateLimitFilter extends OncePerRequestFilter {

	private static final long WINDOW_S = 60;

	private final StringRedisTemplate valkey;

	private final CircuitBreaker breaker;

	private final int getLimit;

	private final int postLimit;

	private final ConcurrentHashMap<String, AtomicLong> local = new ConcurrentHashMap<>();

	private volatile long localWindow = -1;

	RateLimitFilter(StringRedisTemplate valkey, CircuitBreakerFactory<?, ?> breakers,
			@Value("${cloudbridge.rate-limit.get-per-minute}") int getLimit,
			@Value("${cloudbridge.rate-limit.order-post-per-minute}") int postLimit) {
		this.valkey = valkey;
		this.breaker = breakers.create("valkey");
		this.getLimit = getLimit;
		this.postLimit = postLimit;
	}

	@Override
	protected boolean shouldNotFilter(HttpServletRequest req) {
		String uri = req.getRequestURI();
		return uri.startsWith("/healthz/") || uri.startsWith("/admin/") || uri.startsWith("/actuator/")
				|| uri.startsWith("/fallback/") || "OPTIONS".equals(req.getMethod());
	}

	@Override
	protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
			throws ServletException, IOException {
		boolean write = "POST".equals(req.getMethod());
		int limit = write ? this.postLimit : this.getLimit;
		long now = Instant.now().getEpochSecond();
		long window = now / WINDOW_S;
		String key = "rl:" + clientKey(req) + ":" + (write ? "w" : "r") + ":" + window;

		long count = this.breaker.run(() -> {
			Long n = this.valkey.opsForValue().increment(key);
			if (n != null && n == 1) {
				this.valkey.expire(key, Duration.ofSeconds(WINDOW_S));
			}
			return (n != null) ? n : 0L;
		}, (err) -> localIncrement(key, window));

		long reset = WINDOW_S - (now % WINDOW_S);
		res.setHeader("RateLimit-Limit", String.valueOf(limit));
		res.setHeader("RateLimit-Remaining", String.valueOf(Math.max(0, limit - count)));
		res.setHeader("RateLimit-Reset", String.valueOf(reset));
		if (count > limit) {
			res.setHeader("Retry-After", String.valueOf(reset));
			ProblemWriter.write(res, Problems.RATE_LIMITED.detail("limit " + limit + " per minute"));
			return;
		}
		chain.doFilter(req, res);
	}

	/** Trusted only because the origin accepts nothing but Cloudflare (origin lock-down). */
	private static String clientKey(HttpServletRequest req) {
		String ip = req.getHeader("CF-Connecting-IP");
		return (ip != null && !ip.isBlank()) ? ip : req.getRemoteAddr();
	}

	private long localIncrement(String key, long window) {
		if (window != this.localWindow) {
			this.local.clear();
			this.localWindow = window;
		}
		return this.local.computeIfAbsent(key, (k) -> new AtomicLong()).incrementAndGet();
	}

}
