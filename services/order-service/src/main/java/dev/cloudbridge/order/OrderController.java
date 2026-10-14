package dev.cloudbridge.order;

import dev.cloudbridge.common.Problems;
import dev.cloudbridge.order.OrderModels.CreateOrder;
import dev.cloudbridge.order.OrderModels.Created;
import dev.cloudbridge.order.OrderModels.DependencyUnavailable;
import dev.cloudbridge.order.OrderModels.InProgress;
import dev.cloudbridge.order.OrderModels.Mismatch;
import dev.cloudbridge.order.OrderModels.OrderSummary;
import dev.cloudbridge.order.OrderModels.OutOfStock;
import dev.cloudbridge.order.OrderModels.Replayed;
import jakarta.validation.Valid;

import org.springframework.http.CacheControl;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/orders")
class OrderController {

	private final IdempotentOrderService orders;

	private final OrderQueries queries;

	OrderController(IdempotentOrderService orders, OrderQueries queries) {
		this.orders = orders;
		this.queries = queries;
	}

	@PostMapping
	ResponseEntity<?> create(@RequestHeader(name = "Idempotency-Key", required = false) String rawKey,
			@Valid @RequestBody CreateOrder req) {
		UUID key = parseKey(rawKey);
		if (key == null) {
			return problem(Problems.MISSING_IDEMPOTENCY_KEY, "send a UUID Idempotency-Key per logical order");
		}
		if (req.hasDuplicateSkus()) {
			return problem(Problems.VALIDATION_FAILED, "each sku may appear once per order");
		}
		return switch (this.orders.create(key, req)) {
			case Created c -> ResponseEntity.created(URI.create("/orders/" + c.body().orderId()))
				.cacheControl(CacheControl.noStore())
				.contentType(MediaType.APPLICATION_JSON)
				.body(c.json());
			case Replayed r -> ResponseEntity.status(r.status())
				.header("Idempotent-Replayed", "true")
				.cacheControl(CacheControl.noStore())
				.contentType(MediaType.APPLICATION_JSON)
				.body(r.json());
			case InProgress p -> withRetryAfter(problem(Problems.REQUEST_IN_PROGRESS, "a request with this key is in progress"), "1");
			case Mismatch m -> problem(Problems.IDEMPOTENCY_KEY_REUSED, "Idempotency-Key reused with a different body");
			case OutOfStock o -> {
				ProblemDetail pd = Problems.OUT_OF_STOCK_IN_CELL.detail(o.sku() + " has no sellable quantity under this cell's lease");
				pd.setProperty("sku", o.sku());
				yield ResponseEntity.status(pd.getStatus()).contentType(MediaType.APPLICATION_PROBLEM_JSON).body(pd);
			}
			case DependencyUnavailable d -> withRetryAfter(problem(Problems.DEPENDENCY_UNAVAILABLE, d.dependency() + " is unavailable"), "2");
		};
	}

	@GetMapping("/{id}")
	ResponseEntity<?> get(@PathVariable UUID id) {
		return this.queries.find(id)
			.<ResponseEntity<?>>map((o) -> ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(o))
			.orElseGet(() -> problem(Problems.NOT_FOUND, "no order " + id + " in this cell"));
	}

	@GetMapping
	ResponseEntity<List<OrderSummary>> list(@RequestParam UUID customerId,
			@RequestParam(defaultValue = "20") int limit) {
		return ResponseEntity.ok()
			.cacheControl(CacheControl.noStore())
			.body(this.queries.byCustomer(customerId, Math.clamp(limit, 1, 50)));
	}

	private static UUID parseKey(String raw) {
		try {
			return (raw != null) ? UUID.fromString(raw) : null;
		}
		catch (IllegalArgumentException ex) {
			return null;
		}
	}

	static ResponseEntity<?> problem(Problems p, String detail) {
		return ResponseEntity.status(p.status).contentType(MediaType.APPLICATION_PROBLEM_JSON).body(p.detail(detail));
	}

	private static ResponseEntity<?> withRetryAfter(ResponseEntity<?> response, String seconds) {
		return ResponseEntity.status(response.getStatusCode())
			.headers(response.getHeaders())
			.header(HttpHeaders.RETRY_AFTER, seconds)
			.body(response.getBody());
	}

}
