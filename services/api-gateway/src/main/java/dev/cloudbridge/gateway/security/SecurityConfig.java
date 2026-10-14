package dev.cloudbridge.gateway.security;

import jakarta.servlet.DispatcherType;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;

/**
 * Public chain: an explicit allowlist of routes; everything else, including any /admin/** path,
 * answers 404 so the public host never admits that admin paths exist. The admin chain (Cloudflare
 * Access JWT on the per-cell admin hostname) arrives with the lease API in Week 4 — see
 * cloudbridge-cell-services references/security-and-api.md.
 */
@Configuration(proxyBeanMethods = false)
class SecurityConfig {

	private static final PathPatternRequestMatcher.Builder PATHS = PathPatternRequestMatcher.withDefaults();

	@Bean
	SecurityFilterChain publicChain(HttpSecurity http) throws Exception {
		http.authorizeHttpRequests((a) -> a
			.dispatcherTypeMatchers(DispatcherType.FORWARD, DispatcherType.ERROR).permitAll() // breaker fallback, error page
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
			.csrf((c) -> c.disable()) // stateless JSON API; no cookie-based auth
			.cors(Customizer.withDefaults()) // CorsConfigurationSource bean in CorsConfig
			.headers((h) -> h.contentTypeOptions(Customizer.withDefaults()));
		return http.build();
	}

}
