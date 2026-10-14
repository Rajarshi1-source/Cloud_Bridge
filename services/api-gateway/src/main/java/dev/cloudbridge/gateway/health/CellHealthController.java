package dev.cloudbridge.gateway.health;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * "Can this cell take orders?" — the question Cloudflare's monitor asks before routing a user here.
 * UP = gateway serving AND order-service ready AND the cell DB answers. The cache is deliberately
 * NOT checked: a cold or failed Valkey costs latency, it must not drain a whole cloud. The result
 * is cached briefly so probes from several Cloudflare regions don't hammer the database.
 */
@RestController
class CellHealthController {

	private final OrderReadinessProbe orderService;

	private final JdbcClient db;

	private final String cell;

	private final Duration cacheTtl;

	private final AtomicReference<Snapshot> last = new AtomicReference<>(new Snapshot(Instant.EPOCH, false, false));

	CellHealthController(OrderReadinessProbe orderService, JdbcClient db, @Value("${cloudbridge.cell}") String cell,
			@Value("${cloudbridge.health.cache-ttl:2s}") Duration cacheTtl) {
		this.orderService = orderService;
		this.db = db;
		this.cell = cell;
		this.cacheTtl = cacheTtl;
	}

	@GetMapping("/healthz/cell")
	ResponseEntity<Map<String, Object>> health() {
		Snapshot s = this.last.get();
		if (!s.at().isAfter(Instant.now().minus(this.cacheTtl))) {
			s = new Snapshot(Instant.now(), this.orderService.ready(), dbReachable());
			this.last.set(s);
		}
		boolean up = s.orderService() && s.database();
		Map<String, Object> body = new LinkedHashMap<>();
		body.put("cell", this.cell);
		body.put("status", up ? "UP" : "DOWN");
		body.put("orderService", s.orderService() ? "UP" : "DOWN");
		body.put("database", s.database() ? "UP" : "DOWN");
		return ResponseEntity.status(up ? 200 : 503).cacheControl(CacheControl.noStore()).body(body);
	}

	private boolean dbReachable() {
		try {
			Integer one = this.db.sql("SELECT 1").query(Integer.class).single();
			return one != null && one == 1;
		}
		catch (RuntimeException ex) {
			return false;
		}
	}

	private record Snapshot(Instant at, boolean orderService, boolean database) {
	}

}
