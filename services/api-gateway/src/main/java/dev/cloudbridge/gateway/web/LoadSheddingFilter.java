package dev.cloudbridge.gateway.web;

import dev.cloudbridge.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.concurrent.Semaphore;

/**
 * Past the in-flight limit the gateway answers 503 + Retry-After at once instead of queueing.
 * /healthz/cell is exempt: shedding is graceful degradation, so the cell stays in the pool.
 */
@Component
@Order(5) // before rate limiting: shedding is cheaper than a Valkey round trip
class LoadSheddingFilter extends OncePerRequestFilter {

	private final Semaphore inFlight;

	LoadSheddingFilter(@Value("${cloudbridge.shedding.max-in-flight}") int maxInFlight) {
		this.inFlight = new Semaphore(maxInFlight);
	}

	@Override
	protected boolean shouldNotFilter(HttpServletRequest req) {
		String uri = req.getRequestURI();
		return uri.startsWith("/healthz/") || uri.startsWith("/actuator/");
	}

	@Override
	protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
			throws ServletException, IOException {
		if (!this.inFlight.tryAcquire()) {
			res.setHeader("Retry-After", "2");
			ProblemWriter.write(res, Problems.OVERLOADED.detail("in-flight limit reached"));
			return;
		}
		try {
			chain.doFilter(req, res);
		}
		finally {
			this.inFlight.release();
		}
	}

}
