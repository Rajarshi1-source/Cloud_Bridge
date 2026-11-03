package dev.cloudbridge.gateway.security;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.security.web.csrf.CsrfTokenRepository;
import org.springframework.security.web.csrf.DefaultCsrfToken;

import java.util.UUID;

/**
 * CSRF without a session. Spring's default store opens an HttpSession for every unsafe request it
 * checks, so anonymous POSTs to unlisted routes would each cost a session and answer with a cookie.
 * This one stores nothing: no token can ever match, so such a request is always refused.
 */
final class StatelessCsrfTokenRepository implements CsrfTokenRepository {

	@Override
	public CsrfToken generateToken(HttpServletRequest request) {
		return new DefaultCsrfToken("X-CSRF-TOKEN", "_csrf", UUID.randomUUID().toString());
	}

	@Override
	public void saveToken(CsrfToken token, HttpServletRequest request, HttpServletResponse response) {
	}

	@Override
	public CsrfToken loadToken(HttpServletRequest request) {
		return null;
	}

}
