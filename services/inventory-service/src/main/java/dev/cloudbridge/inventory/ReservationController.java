package dev.cloudbridge.inventory;

import dev.cloudbridge.common.Problems;
import dev.cloudbridge.inventory.ReservationService.Result;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * Internal API for order-service in the same cell. Never routed by the gateway; NetworkPolicy
 * admits only order-service pods.
 */
@RestController
@RequestMapping("/reservations")
class ReservationController {

	record ReserveRequest(@NotNull UUID reservationId, @NotBlank String sku, @Min(1) @Max(100) int qty) {
	}

	private final ReservationService reservations;

	ReservationController(ReservationService reservations) {
		this.reservations = reservations;
	}

	@PostMapping
	ResponseEntity<?> reserve(@Valid @RequestBody ReserveRequest req) {
		Result result;
		try {
			result = this.reservations.reserve(req.reservationId(), req.sku(), req.qty());
		}
		catch (DuplicateKeyException ex) {
			// A concurrent first attempt with the same id won; ours rolled back. Now it's a replay.
			result = this.reservations.reserve(req.reservationId(), req.sku(), req.qty());
		}
		return switch (result) {
			case CREATED -> ResponseEntity.status(HttpStatus.CREATED).body(Map.of("result", "CREATED"));
			case REPLAYED -> ResponseEntity.ok(Map.of("result", "REPLAYED"));
			case OUT_OF_STOCK -> {
				ProblemDetail pd = Problems.OUT_OF_STOCK_IN_CELL
					.detail(req.sku() + " has no sellable quantity under this cell's lease");
				pd.setProperty("sku", req.sku());
				yield ResponseEntity.status(pd.getStatus()).contentType(MediaType.APPLICATION_PROBLEM_JSON).body(pd);
			}
		};
	}

	@PostMapping("/{id}/release")
	Map<String, Integer> release(@PathVariable UUID id) {
		return Map.of("released", this.reservations.release(id));
	}

	@PostMapping("/{id}/confirm")
	Map<String, Integer> confirm(@PathVariable UUID id) {
		return Map.of("confirmed", this.reservations.confirm(id));
	}

}
