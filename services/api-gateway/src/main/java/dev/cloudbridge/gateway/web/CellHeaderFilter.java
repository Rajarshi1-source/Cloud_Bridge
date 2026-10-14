package dev.cloudbridge.gateway.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * X-CB-Cell on EVERY response — including 404s from security, 429s and 503s — so the demo (and
 * anyone debugging affinity) can always see which cloud answered. Runs before Spring Security.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
class CellHeaderFilter extends OncePerRequestFilter {

	private final String cell;

	CellHeaderFilter(@Value("${cloudbridge.cell}") String cell) {
		this.cell = cell;
	}

	@Override
	protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
			throws ServletException, IOException {
		res.setHeader("X-CB-Cell", this.cell);
		chain.doFilter(req, res);
	}

}
