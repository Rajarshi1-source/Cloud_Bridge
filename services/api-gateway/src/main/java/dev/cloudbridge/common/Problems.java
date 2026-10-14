package dev.cloudbridge.common;

import org.slf4j.MDC;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ProblemDetail;

import java.net.URI;

/**
 * RFC 9457 problem catalog shared by every cell service (one identical copy per service).
 * Clients switch on {@code type}, never on {@code detail} text.
 */
public enum Problems {

	MISSING_IDEMPOTENCY_KEY(400, "missing-idempotency-key", "Idempotency-Key header required"),
	VALIDATION_FAILED(400, "validation-failed", "Request validation failed"),
	NOT_FOUND(404, "not-found", "Not found"),
	OUT_OF_STOCK_IN_CELL(409, "out-of-stock-in-cell", "Out of stock in this cell"),
	REQUEST_IN_PROGRESS(409, "request-in-progress", "Request with this key is in progress"),
	STALE_LEASE_EPOCH(409, "stale-lease-epoch", "Lease epoch is stale or already used"),
	PAYLOAD_TOO_LARGE(413, "payload-too-large", "Payload too large"),
	IDEMPOTENCY_KEY_REUSED(422, "idempotency-key-reused", "Idempotency-Key reused with a different body"),
	LEASE_GRANT_OUT_OF_BOUNDS(422, "lease-grant-out-of-bounds", "Lease grant outside allowed bounds"),
	RATE_LIMITED(429, "rate-limited", "Too many requests"),
	OVERLOADED(503, "overloaded", "Cell is shedding load"),
	DEPENDENCY_UNAVAILABLE(503, "dependency-unavailable", "A required dependency is unavailable");

	private static final String BASE = System.getenv().getOrDefault("CB_PROBLEM_BASE", "https://cloudbridge.example/problems/");

	private static final String CELL = System.getenv().getOrDefault("CB_CELL", "unknown");

	public final int status;

	public final String slug;

	public final String title;

	Problems(int status, String slug, String title) {
		this.status = status;
		this.slug = slug;
		this.title = title;
	}

	public ProblemDetail detail(String detail) {
		ProblemDetail pd = ProblemDetail.forStatusAndDetail(HttpStatusCode.valueOf(this.status), detail);
		pd.setType(URI.create(BASE + this.slug));
		pd.setTitle(this.title);
		pd.setProperty("cell", CELL);
		String traceId = MDC.get("traceId");
		if (traceId != null) {
			pd.setProperty("traceId", traceId);
		}
		return pd;
	}

}
