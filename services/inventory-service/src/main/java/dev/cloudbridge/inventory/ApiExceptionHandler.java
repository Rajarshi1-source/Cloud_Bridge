package dev.cloudbridge.inventory;

import dev.cloudbridge.common.Problems;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;

import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.context.request.WebRequest;
import org.springframework.web.servlet.mvc.method.annotation.ResponseEntityExceptionHandler;

import java.util.List;
import java.util.Map;

/** Every error leaves this service as application/problem+json with a stable type slug. */
@RestControllerAdvice
class ApiExceptionHandler extends ResponseEntityExceptionHandler {

	@Override
	protected ResponseEntity<Object> handleMethodArgumentNotValid(MethodArgumentNotValidException ex,
			HttpHeaders headers, HttpStatusCode status, WebRequest request) {
		ProblemDetail pd = Problems.VALIDATION_FAILED.detail("request validation failed");
		List<Map<String, String>> errors = ex.getBindingResult()
			.getFieldErrors()
			.stream()
			.map((e) -> Map.of("field", e.getField(), "message", String.valueOf(e.getDefaultMessage())))
			.toList();
		pd.setProperty("errors", errors);
		return ResponseEntity.status(pd.getStatus()).contentType(MediaType.APPLICATION_PROBLEM_JSON).body(pd);
	}

	@ExceptionHandler(CallNotPermittedException.class)
	ResponseEntity<ProblemDetail> breakerOpen(CallNotPermittedException ex) {
		ProblemDetail pd = Problems.DEPENDENCY_UNAVAILABLE.detail(ex.getMessage());
		return ResponseEntity.status(pd.getStatus())
			.header(HttpHeaders.RETRY_AFTER, "2")
			.contentType(MediaType.APPLICATION_PROBLEM_JSON)
			.body(pd);
	}

}
