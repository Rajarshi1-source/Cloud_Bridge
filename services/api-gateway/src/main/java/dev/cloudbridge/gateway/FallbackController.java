package dev.cloudbridge.gateway;

import dev.cloudbridge.common.Problems;

import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Where an open breaker (or an upstream 5xx after retries) lands: a 503 the client can retry. */
@RestController
class FallbackController {

	@RequestMapping("/fallback/unavailable")
	ResponseEntity<ProblemDetail> unavailable() {
		ProblemDetail pd = Problems.DEPENDENCY_UNAVAILABLE.detail("upstream service in this cell is unavailable");
		return ResponseEntity.status(pd.getStatus())
			.header(HttpHeaders.RETRY_AFTER, "2")
			.contentType(MediaType.APPLICATION_PROBLEM_JSON)
			.body(pd);
	}

}
