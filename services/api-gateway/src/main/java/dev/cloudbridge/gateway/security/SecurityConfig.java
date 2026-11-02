package dev.cloudbridge.gateway.security;

import jakarta.servlet.DispatcherType;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.web.BearerTokenResolver;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;
import org.springframework.security.web.util.matcher.AndRequestMatcher;
import org.springframework.security.web.util.matcher.RequestMatcher;

/**
 * Admin chain: the per-cell admin hostname and /admin/** only, behind the Cloudflare Access JWT.
 * Public chain: an explicit allowlist of routes; everything else, including any /admin/** path and
 * every other path on the admin host, answers 404 so the public host never admits that admin paths
 * exist. See cloudbridge-cell-services references/security-and-api.md.
 */
@Configuration(proxyBeanMethods = false)
class SecurityConfig {

	private static final PathPatternRequestMatcher.Builder PATHS = PathPatternRequestMatcher.withDefaults();

	static RequestMatcher hostIs(String host) {
		return (request) -> host.equalsIgnoreCase(request.getServerName());
	}

	/** Unauthenticated → 401, wrong service token → 403. */
	@Bean
	@Order(1)
	SecurityFilterChain adminChain(HttpSecurity http, AdminProperties props, BearerTokenResolver resolver,
			JwtDecoder decoder, JwtAuthenticationConverter converter) throws Exception {
		http.securityMatcher(new AndRequestMatcher(hostIs(props.host()), PATHS.matcher("/admin/**")))
			.authorizeHttpRequests((a) -> a
				.requestMatchers(PATHS.matcher(HttpMethod.POST, "/admin/leases/grant"),
						PATHS.matcher(HttpMethod.GET, "/admin/leases/report"))
				.hasAuthority(CfAccessJwtConfig.ROLE_LEASE_ALLOCATOR)
				.anyRequest()
				.denyAll())
			.oauth2ResourceServer((o) -> o.bearerTokenResolver(resolver)
				.jwt((j) -> j.decoder(decoder).jwtAuthenticationConverter(converter)))
			.sessionManagement((s) -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
			.csrf((c) -> c.ignoringRequestMatchers(PATHS.matcher("/admin/**"))) // header-authenticated, no cookies
			.cors((c) -> c.disable()); // no browser ever calls the admin API
		return http.build();
	}

	@Bean
	@Order(2)
	SecurityFilterChain publicChain(HttpSecurity http, AdminProperties props) throws Exception {
		http.authorizeHttpRequests((a) -> a
			.dispatcherTypeMatchers(DispatcherType.FORWARD, DispatcherType.ERROR).permitAll() // breaker fallback, error page
			.requestMatchers(hostIs(props.host())).denyAll()
			.requestMatchers(PATHS.matcher("/admin/**")).denyAll()
			.requestMatchers(PATHS.matcher(HttpMethod.GET, "/healthz/cell")).permitAll()
			.requestMatchers(PATHS.matcher("/actuator/health/**"), PATHS.matcher("/actuator/prometheus"),
					PATHS.matcher("/actuator/info"))
			.permitAll() // management port 9080, NetworkPolicy-guarded
			.requestMatchers(PATHS.matcher(HttpMethod.POST, "/orders"), PATHS.matcher(HttpMethod.GET, "/orders"),
					PATHS.matcher(HttpMethod.GET, "/orders/*"), PATHS.matcher(HttpMethod.GET, "/inventory/*"))
			.permitAll()
			.requestMatchers(PATHS.matcher(HttpMethod.OPTIONS, "/**"))
			.permitAll()
			.anyRequest()
			.denyAll())
			.exceptionHandling((e) -> e
				.authenticationEntryPoint((req, res, ex) -> res.sendError(HttpServletResponse.SC_NOT_FOUND))
				.accessDeniedHandler((req, res, ex) -> res.sendError(HttpServletResponse.SC_NOT_FOUND)))
			.sessionManagement((s) -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
			.csrf((c) -> c.ignoringRequestMatchers(PATHS.matcher(HttpMethod.POST, "/orders"))) // no cookie-based auth
			.cors(Customizer.withDefaults()) // CorsConfigurationSource bean in CorsConfig
			.headers((h) -> h.contentTypeOptions(Customizer.withDefaults()));
		return http.build();
	}

}
