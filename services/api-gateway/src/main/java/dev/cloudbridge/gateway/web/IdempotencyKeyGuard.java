package dev.cloudbridge.gateway.web;

import dev.cloudbridge.common.Problems;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.UUID;

/** POST /orders without a UUID Idempotency-Key never reaches order-service, so retries can't duplicate it. */
@Component
@Order(10)
class IdempotencyKeyGuard extends OncePerRequestFilter {

	@Override
	protected boolean shouldNotFilter(HttpServletRequest req) {
		return !("POST".equals(req.getMethod()) && "/orders".equals(req.getRequestURI()));
	}

	@Override
	protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
			throws ServletException, IOException {
		String key = req.getHeader("Idempotency-Key");
		try {
			UUID.fromString((key != null) ? key : "");
		}
		catch (IllegalArgumentException ex) {
			ProblemWriter.write(res, Problems.MISSING_IDEMPOTENCY_KEY.detail("send a UUID Idempotency-Key per logical order"));
			return;
		}
		chain.doFilter(req, res);
	}

}
